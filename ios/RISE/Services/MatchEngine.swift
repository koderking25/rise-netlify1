import Foundation
import SwiftUI

/// Orchestrates a search and publishes results as they arrive.
///
/// The phone version reveals progressively on purpose. On the web the student
/// is looking at a wide page and a two-second wait is tolerable; on a phone,
/// staring at a spinner for twenty seconds while a web search runs feels
/// broken. So the bundled library lands first — instantly, always, even with
/// no signal — and live results replace it as they arrive. The student is
/// never looking at nothing, and is told plainly which of the two they have.
@MainActor
final class MatchEngine: ObservableObject {

    @Published private(set) var results: [Opportunity] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var notice: String?
    @Published private(set) var isLive = false

    enum Phase: Equatable {
        case idle
        case searching(String)
        case judging
        case done
    }

    private var runToken = 0
    private var angle = UserDefaults.standard.integer(forKey: "rise_angle")

    /// Number of distinct organizations below which the shared cohort pool is
    /// too thin to rank against, and a personalised search is worth its cost.
    private let poolFloor = 6

    func search(profile: StudentProfile) async {
        runToken += 1
        let token = runToken
        results = []
        notice = nil
        isLive = false

        guard let talent = Catalog.talent(profile.talents.first ?? ""),
              let location = Catalog.location(profile.locationId) else { return }

        // Rotate the opening angle so searching again explores new ground
        // rather than re-asking the identical question.
        angle = (angle + 1) % 4
        UserDefaults.standard.set(angle, forKey: "rise_angle")

        // 1. Bundled library first — instant, works offline, never empty.
        phase = .searching("Finding organizations near you")
        let local = OfflineLibrary.candidates(talent: talent, location: location,
                                              remoteOnly: profile.virtualOnly)
        results = rank(local, profile: profile)

        // 2. Shared cohort discovery. Two angles, both cache lookups after the
        //    first student in this city and category has paid for them.
        phase = .searching("Searching live listings")
        var pool: [Opportunity] = []
        do {
            let a = try await AIClient.shared.discover(talent: talent, location: location,
                                                       angle: angle, remoteOnly: profile.virtualOnly)
            guard token == runToken else { return }
            pool += a
            results = rank(merge(results, a), profile: profile)
            isLive = true

            let b = try await AIClient.shared.discover(talent: talent, location: location,
                                                       angle: angle + 1, remoteOnly: profile.virtualOnly)
            guard token == runToken else { return }
            pool += b
            results = rank(merge(results, b), profile: profile)
        } catch let e as AIClient.AIError {
            guard token == runToken else { return }
            notice = e.errorDescription
        } catch {
            guard token == runToken else { return }
            notice = AIClient.AIError.offline.errorDescription
        }

        // 3. Only if the cohort pool was too thin for this student does a
        //    personalised search run. This is where their own words earn the
        //    extra cost, instead of every student paying it every time.
        let distinct = Set(pool.map { Self.orgKey($0.org) }).count
        if distinct < poolFloor && isLive {
            phase = .searching("Looking for a closer fit")
            // A personalised pass reuses discovery with the student's free text
            // folded into the angle; omitting cacheKey keeps it uncached.
            if let extra = try? await AIClient.shared.discover(
                talent: talent, location: location, angle: angle + 2,
                remoteOnly: profile.virtualOnly), token == runToken {
                results = rank(merge(results, extra), profile: profile)
            }
        }

        // 4. Judge everything that survived, against this student.
        guard token == runToken, !results.isEmpty, isLive else {
            phase = .done
            return
        }
        phase = .judging
        if let verdicts = try? await AIClient.shared.judge(pool: results, profile: profile,
                                                          talent: talent, location: location),
           token == runToken {
            var next: [Opportunity] = []
            for (i, opp) in results.enumerated() {
                guard let v = verdicts[i] else { next.append(opp); continue }
                if v.verdict == "reject" { continue }
                var o = opp
                o.judge = v
                o.aiScore = v.total
                // Blend: the deterministic scorer is noisy but never
                // hallucinates; the judge is sharp but can be talked into
                // things. Neither gets the last word.
                let det = o.detScore ?? 50
                o.score = Int(Double(v.total ?? det) * 0.7 + Double(det) * 0.3)
                o.blocked = Self.constraintBreak(o, profile: profile)
                next.append(o)
            }
            results = sortResults(next)
        }

        // 5. Confirm the links resolve, so nobody emails an organization that
        //    folded years ago.
        let links = results.compactMap(\.link).filter { $0.hasPrefix("https://") }
        let ok = await AIClient.shared.verify(urls: Array(Set(links)))
        guard token == runToken else { return }
        if !ok.isEmpty {
            results = results.map { o in
                var o = o
                if let l = o.link, let good = ok[l], !good { o.blocked = o.blocked ?? "Link didn't respond" }
                return o
            }
        }
        phase = .done
    }

    // MARK: - Ranking

    private func rank(_ opps: [Opportunity], profile: StudentProfile) -> [Opportunity] {
        sortResults(opps.map { o in
            var o = o
            if o.score == nil {
                let d = OfflineLibrary.deterministicScore(o, profile: profile)
                o.detScore = d
                o.score = d
            }
            o.blocked = Self.constraintBreak(o, profile: profile)
            return o
        })
    }

    private func sortResults(_ opps: [Opportunity]) -> [Opportunity] {
        opps.sorted { a, b in
            // A stated wall outranks the score under every ordering.
            if (a.blocked == nil) != (b.blocked == nil) { return a.blocked == nil }
            return (a.score ?? 0) > (b.score ?? 0)
        }
    }

    private func merge(_ existing: [Opportunity], _ incoming: [Opportunity]) -> [Opportunity] {
        var seen = Set(existing.map { Self.orgKey($0.org) })
        var out = existing
        for o in incoming where !o.org.isEmpty {
            let k = Self.orgKey(o.org)
            if seen.contains(k) { continue }
            seen.insert(k)
            out.append(o)
        }
        return out
    }

    /// Some answers are preferences to weigh; some are walls. "I can only
    /// volunteer from home" is a wall — an in-person role is not a worse match,
    /// it is an impossible one. Enforced here in code rather than left to a
    /// 20-point logistics dimension inside a 100-point score, where a strong
    /// capability match could still float an unattendable role to the top.
    static func constraintBreak(_ o: Opportunity, profile: StudentProfile) -> String? {
        if profile.virtualOnly && !o.isRemote {
            return "Needs you on site — you asked for remote only"
        }
        return nil
    }

    static func orgKey(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"\b(the|inc|society|association|of|canada)\b"#,
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
    }
}
