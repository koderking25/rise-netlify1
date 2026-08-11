import Foundation

// MARK: - Opportunity

/// One volunteer role. Field names match the JSON the Worker proxy returns for
/// the web app, so a single server contract serves both clients — including
/// `remote`, which the pipeline added so a stated "remote only" answer could be
/// enforced in code instead of being left to the model's judgement.
struct Opportunity: Codable, Identifiable, Hashable {
    var id: String { "\(org)|\(title)" }

    var title: String
    var org: String
    var role: String?
    var whyMatch: String?
    var commitment: String?
    var firstStep: String?
    var requirements: String?
    var whereText: String?
    var hours: String?
    var link: String?
    var contactEmail: String?
    var sourceUrl: String?
    var remote: Bool?
    var tags: [String]?

    // Scoring, filled in client-side after the judge returns.
    var score: Int?
    var aiScore: Int?
    var detScore: Int?
    var judge: JudgeVerdict?
    /// Non-nil when the role breaks something the student said was a hard
    /// requirement. Carries the reason so the card can say it out loud.
    var blocked: String?
    var origin: String?
    var curated: Bool?

    enum CodingKeys: String, CodingKey {
        case title, org, role, whyMatch, commitment, firstStep, requirements
        case whereText = "where"
        case hours, link, contactEmail, sourceUrl, remote, tags
    }

    /// Best guess at whether this is doable from home. Prefers the model's
    /// explicit flag and only falls back to prose for older cached results —
    /// the same precedence the web client uses.
    var isRemote: Bool {
        if let r = remote { return r }
        let hay = ((whereText ?? "") + " " + (tags ?? []).joined(separator: " ")).lowercased()
        return ["remote", "virtual", "online", "from home", "anywhere"].contains { hay.contains($0) }
    }

    /// Can the student act on this today without hunting for who to ask?
    var isActionable: Bool {
        (contactEmail?.isEmpty == false) || (firstStep?.isEmpty == false)
    }

    var verdict: Verdict {
        switch score ?? 0 {
        case 78...:  return .strong
        case 58..<78: return .good
        default:      return .starting
        }
    }
}

enum Verdict: String {
    case strong, good, starting
    var label: String {
        switch self {
        case .strong:   return "Strong match"
        case .good:     return "Good match"
        case .starting: return "Starting point"
        }
    }
}

struct JudgeVerdict: Codable, Hashable {
    var capability: Int?
    var population: Int?
    var logistics: Int?
    var credibility: Int?
    var total: Int?
    var evidence: String?
    var verdict: String?
}

// MARK: - Student profile

struct StudentProfile: Codable, Equatable {
    var name = ""
    var locationId = ""
    var talents: [String] = []
    var capabilities: [String] = []
    var languages: [String] = []
    var detail = ""
    var serve: [String] = []
    var availability = ""
    var setting = ""
    var showUp = ""
    var why = ""

    var virtualOnly: Bool { showUp == "homunteer" || locationId == "virtual" }

    var isComplete: Bool {
        !name.isEmpty && !locationId.isEmpty && !talents.isEmpty
    }
}

// MARK: - Reference data

struct Talent: Identifiable, Hashable {
    let id: String
    let label: String
    let blurb: String
    let symbol: String   // SF Symbol
    let capabilities: [Capability]
}

struct Capability: Identifiable, Hashable {
    let id: String
    let text: String
}

struct RLocation: Identifiable, Hashable {
    let id: String
    let label: String
    let short: String
    let province: String
}

// MARK: - Hours

/// One logged volunteering session. `verified` is deliberately present and
/// deliberately unused by the app itself: schools accept a record when a
/// supervisor stands behind it, and this is the field that will carry that
/// once sign-off exists. Storing it from the start means existing entries do
/// not need migrating later.
struct HourEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var org: String
    var role: String
    var date: Date
    var hours: Double
    var note: String = ""
    var verified: Bool = false
    var supervisorName: String = ""
    var supervisorEmail: String = ""
}
