import SwiftUI

struct ResultsView: View {
    @ObservedObject var engine: MatchEngine
    @EnvironmentObject var store: Store
    var onRetake: () -> Void

    @State private var format: Format = .any
    @State private var onlyActionable = false

    enum Format: String, CaseIterable { case any = "Any", remote = "Remote", onsite = "In person" }

    private var visible: [Opportunity] {
        engine.results.filter { o in
            switch format {
            case .any: return true
            case .remote: return o.isRemote
            case .onsite: return !o.isRemote
            }
        }
        .filter { !onlyActionable || $0.isActionable }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let n = engine.notice { noticeBar(n) }
                if engine.results.count > 2 { filters }

                if visible.isEmpty && !engine.results.isEmpty {
                    emptyFiltered
                } else {
                    ForEach(visible) { opp in
                        OpportunityCard(opp: opp, profile: store.profile)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }
            .padding(.horizontal, RISE.M.gutter)
            .padding(.bottom, 40)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: visible.count)
        }
        .background(RISE.C.canvas)
        .overlay(alignment: .top) { if isWorking { workingBar } }
    }

    private var isWorking: Bool {
        if case .done = engine.phase { return false }
        if case .idle = engine.phase { return false }
        return true
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: engine.isLive ? "checkmark.seal.fill" : "books.vertical.fill")
                    .foregroundStyle(engine.isLive ? RISE.C.success : RISE.C.ink3)
                Text(engine.isLive
                     ? "\(engine.results.count) live matches"
                     : "\(engine.results.count) starting points")
                    .font(RISE.F.body(13, .semibold))
                    .foregroundStyle(RISE.C.ink2)
                Spacer()
                Button("Retake", action: onRetake)
                    .font(RISE.F.body(13, .medium))
                    .foregroundStyle(RISE.C.fire)
            }
            Text("\(store.profile.name.isEmpty ? "Your" : "\(store.profile.name)'s") matches")
                .font(RISE.F.display(30))
                .foregroundStyle(RISE.C.ink)
        }
        .padding(.top, 8)
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle.fill").foregroundStyle(RISE.C.fire)
            Text(text)
                .font(RISE.F.body(12))
                .foregroundStyle(RISE.C.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RISE.C.ember)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Filters

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Format.allCases, id: \.self) { f in
                    let n = count(for: f)
                    Button {
                        guard n > 0 || f == .any else { return }
                        withAnimation { format = f }
                    } label: {
                        Chip(text: f == .any ? "All (\(engine.results.count))" : "\(f.rawValue) (\(n))",
                             tint: RISE.C.fire, filled: format == f)
                    }
                    .disabled(n == 0 && f != .any)
                    .opacity(n == 0 && f != .any ? 0.4 : 1)
                }
                let act = engine.results.filter(\.isActionable).count
                if act > 0 {
                    Button { withAnimation { onlyActionable.toggle() } } label: {
                        Chip(text: "Can apply now (\(act))", tint: RISE.C.fire, filled: onlyActionable)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func count(for f: Format) -> Int {
        switch f {
        case .any: return engine.results.count
        case .remote: return engine.results.filter(\.isRemote).count
        case .onsite: return engine.results.filter { !$0.isRemote }.count
        }
    }

    private var emptyFiltered: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No matches with these filters — \(engine.results.count) hidden.")
                .font(RISE.F.body(14))
                .foregroundStyle(RISE.C.ink3)
            Button("Clear filters") {
                withAnimation { format = .any; onlyActionable = false }
            }
            .buttonStyle(GhostButtonStyle())
            .frame(width: 150)
        }
        .padding(.vertical, 18)
    }

    // MARK: - Working indicator

    private var workingBar: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small).tint(RISE.C.fire)
            Text(statusText)
                .font(RISE.F.body(12, .medium))
                .foregroundStyle(RISE.C.ink2)
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
        .padding(.top, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var statusText: String {
        switch engine.phase {
        case .searching(let s): return s
        case .judging: return "Weighing each role against what you can do"
        default: return ""
        }
    }
}

// MARK: - Card

struct OpportunityCard: View {
    let opp: Opportunity
    let profile: StudentProfile
    @EnvironmentObject var store: Store
    @State private var showDraft = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Chip(text: opp.verdict.label,
                             tint: opp.verdict == .strong ? RISE.C.success : RISE.C.fire,
                             filled: true)
                        if opp.isRemote { Chip(text: "Remote") }
                    }
                    Text(opp.title)
                        .font(RISE.F.display(20))
                        .foregroundStyle(RISE.C.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(opp.org)
                        .font(RISE.F.body(14, .semibold))
                        .foregroundStyle(RISE.C.fire)
                }
                Spacer(minLength: 8)
                ScoreDial(score: opp.score ?? 0, strong: opp.verdict == .strong)
            }

            // A wall the student told us about, said out loud rather than
            // silently sorted to the bottom.
            if let blocked = opp.blocked {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                    Text(blocked).font(RISE.F.body(12, .medium))
                }
                .foregroundStyle(RISE.C.danger)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RISE.C.dangerBg)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let role = opp.role {
                Text(role)
                    .font(RISE.F.body(14))
                    .foregroundStyle(RISE.C.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let ev = opp.judge?.evidence {
                VStack(alignment: .leading, spacing: 4) {
                    Text("WHY THIS FITS YOU")
                        .font(.system(size: 10, weight: .semibold)).tracking(1)
                        .foregroundStyle(RISE.C.fire)
                    Text(ev)
                        .font(RISE.F.body(13))
                        .italic()
                        .foregroundStyle(RISE.C.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RISE.C.surfaceWarm)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 12) {
                if let c = opp.commitment { meta("clock", c) }
                if let w = opp.whereText { meta("mappin", w) }
            }

            if let step = opp.firstStep, !step.isEmpty {
                Text("First step: \(step)")
                    .font(RISE.F.body(12))
                    .foregroundStyle(RISE.C.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 9) {
                if let link = opp.link, let url = URL(string: link) {
                    Link(destination: url) {
                        Label("Visit", systemImage: "arrow.up.right.square")
                            .font(RISE.F.body(13, .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(RISE.C.fire)
                }
                Button { showDraft = true } label: {
                    Label("Draft email", systemImage: "sparkles")
                        .font(RISE.F.body(13, .semibold))
                }
                .buttonStyle(.bordered)
                .tint(RISE.C.fire)

                Spacer()

                Button { store.toggleSaved(opp) } label: {
                    Image(systemName: store.isSaved(opp) ? "heart.fill" : "heart")
                        .foregroundStyle(store.isSaved(opp) ? RISE.C.fire : RISE.C.ink4)
                }
                .accessibilityLabel(store.isSaved(opp) ? "Remove from saved" : "Save")
            }
            .padding(.top, 2)
        }
        .riseCard()
        .opacity(opp.blocked == nil ? 1 : 0.72)
        .sheet(isPresented: $showDraft) {
            OutreachSheet(opp: opp, profile: profile)
        }
    }

    private func meta(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(text).font(RISE.F.body(12))
        }
        .foregroundStyle(RISE.C.ink3)
    }
}

/// The match score, drawn as a ring rather than a number in a box — it reads
/// faster at a glance on a small screen.
struct ScoreDial: View {
    let score: Int
    let strong: Bool
    var body: some View {
        ZStack {
            Circle().stroke(RISE.C.ink6, lineWidth: 4)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(strong ? RISE.C.success : RISE.C.fire,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: score)
            VStack(spacing: -1) {
                Text("\(score)")
                    .font(RISE.F.body(15, .bold)).monospacedDigit()
                    .foregroundStyle(RISE.C.ink)
                Text("MATCH")
                    .font(.system(size: 6, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(RISE.C.ink4)
            }
        }
        .frame(width: 50, height: 50)
        .accessibilityLabel("Match score \(score) out of 100")
    }
}
