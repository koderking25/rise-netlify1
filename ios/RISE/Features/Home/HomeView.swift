import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: Store
    var goToMatch: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hero
                    if store.totalHours > 0 { progressCard }
                    stats
                    howItWorks
                    honesty
                }
                .padding(.horizontal, RISE.M.gutter)
                .padding(.bottom, 40)
            }
            .background(RISE.C.canvas)
            .navigationTitle("RISE")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("YOUTH VOLUNTEERING · CANADA")
                .font(RISE.F.eyebrow)
                .tracking(1.2)
                .foregroundStyle(RISE.C.ink3)
                .padding(.top, 6)

            // The two-tone display line is the single strongest bit of RISE's
            // identity, so it survives the port intact.
            VStack(alignment: .leading, spacing: -2) {
                Text("Turn talent")
                    .font(RISE.F.display(42))
                    .foregroundStyle(RISE.C.ink)
                Text("into impact.")
                    .font(RISE.F.displayItalic(42))
                    .foregroundStyle(RISE.C.fire)
            }
            .minimumScaleFactor(0.7)
            .lineLimit(1)

            Text("Every young person has something to offer. RISE connects your specific talents to the communities that need exactly that.")
                .font(RISE.F.body(16))
                .foregroundStyle(RISE.C.ink2)
                .lineSpacing(5)

            Button("Find my match", action: goToMatch)
                .buttonStyle(FireButtonStyle())
                .padding(.top, 4)
        }
    }

    // MARK: - Progress

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your hours")
                    .font(RISE.F.body(13, .semibold))
                    .foregroundStyle(RISE.C.ink3)
                Spacer()
                Text("\(store.totalHours, specifier: "%.1f") / \(Int(store.goalHours))")
                    .font(RISE.F.body(13, .semibold))
                    .foregroundStyle(RISE.C.fire)
                    .monospacedDigit()
            }
            ProgressView(value: store.progress)
                .tint(RISE.C.fire)
                .scaleEffect(x: 1, y: 1.6, anchor: .center)
            Text(store.progress >= 1
                 ? "Goal reached. That's a real record you can point to."
                 : "\(Int((store.goalHours - store.totalHours).rounded())) hours to go.")
                .font(RISE.F.body(13))
                .foregroundStyle(RISE.C.ink3)
        }
        .riseCard()
    }

    // MARK: - Stats

    private var stats: some View {
        HStack(spacing: 12) {
            statTile("\(Catalog.locations.count)", "Cities across Canada", "From Vancouver to Halifax")
            statTile("\(Catalog.talents.count)", "Talent categories", "Music, sports & more")
        }
    }

    private func statTile(_ n: String, _ label: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(n)
                .font(RISE.F.display(30))
                .foregroundStyle(RISE.C.fire)
            Text(label)
                .font(RISE.F.body(13, .semibold))
                .foregroundStyle(RISE.C.ink)
            Text(sub)
                .font(RISE.F.body(11))
                .foregroundStyle(RISE.C.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .riseCard(padding: 14)
    }

    // MARK: - How it works

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("From quiz to opportunity")
                .font(RISE.F.display(24))
                .foregroundStyle(RISE.C.ink)

            step("01", "Tell us who you are",
                 "Name, city, talent, specific skills and availability.")
            step("02", "Get matched to real needs",
                 "RISE finds organizations that need exactly what you offer — not generic listings.")
            step("03", "Serve, lead, and grow",
                 "Apply directly, then log hours toward your provincial requirement.")
        }
        .padding(.top, 6)
    }

    private func step(_ n: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(n)
                .font(RISE.F.display(22))
                .foregroundStyle(RISE.C.ink4)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(RISE.F.body(15, .semibold))
                    .foregroundStyle(RISE.C.ink)
                Text(body)
                    .font(RISE.F.body(13))
                    .foregroundStyle(RISE.C.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Honesty strip

    /// Says out loud whether live matching is actually available. The web build
    /// learned this the hard way: silently serving the offline library when the
    /// AI was down is what made every search look identical, and nobody could
    /// tell why.
    @ViewBuilder private var honesty: some View {
        if store.serverLive == false {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(RISE.C.fire)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Live matching is off right now")
                        .font(RISE.F.body(13, .semibold))
                        .foregroundStyle(RISE.C.ink)
                    Text("You'll see real organizations from the built-in library — good places to start, but not tailored to your answers.")
                        .font(RISE.F.body(12))
                        .foregroundStyle(RISE.C.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(RISE.C.ember)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
