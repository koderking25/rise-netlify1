import SwiftUI

/// The five-step questionnaire, then results.
///
/// Rebuilt for touch rather than transliterated from the web wizard: one
/// decision per screen, a thumb-reachable primary action pinned to the bottom,
/// and a swipe-back gesture. Selection uses a chunky tappable row instead of a
/// checkbox, because a 14-year-old is doing this one-handed on a bus.
struct MatchFlowView: View {
    @EnvironmentObject var store: Store
    @StateObject private var engine = MatchEngine()
    @State private var step = 0
    @State private var searching = false

    private let steps = 5

    var body: some View {
        NavigationStack {
            Group {
                if searching {
                    ResultsView(engine: engine, onRetake: {
                        searching = false
                        step = 0
                    })
                } else {
                    wizard
                }
            }
            .background(RISE.C.canvas)
            .navigationTitle(searching ? "Your matches" : "Find your match")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Wizard

    private var wizard: some View {
        VStack(spacing: 0) {
            progressDots
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("STEP \(step + 1) OF \(steps)")
                        .font(RISE.F.eyebrow)
                        .tracking(1.2)
                        .foregroundStyle(RISE.C.fire)

                    switch step {
                    case 0: nameStep
                    case 1: locationStep
                    case 2: talentStep
                    case 3: capabilityStep
                    default: detailStep
                    }
                }
                .padding(.horizontal, RISE.M.gutter)
                .padding(.bottom, 24)
            }
            footer
        }
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<steps, id: \.self) { i in
                Capsule()
                    .fill(i == step ? RISE.C.fire : (i < step ? RISE.C.fire.opacity(0.35) : RISE.C.ink5))
                    .frame(width: i == step ? 22 : 7, height: 7)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
            }
        }
        .padding(.vertical, 14)
    }

    // MARK: - Steps

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hey — what's your name?")
                .font(RISE.F.display(28))
                .foregroundStyle(RISE.C.ink)
            Text("Just for personalisation.")
                .font(RISE.F.body(15))
                .foregroundStyle(RISE.C.ink3)
            TextField("Your first name", text: $store.profile.name)
                .textContentType(.givenName)
                .autocorrectionDisabled()
                .font(RISE.F.body(17))
                .padding(14)
                .background(RISE.C.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(RISE.C.ink5, lineWidth: 1.5))
                .submitLabel(.next)
                .onSubmit { advance() }
        }
    }

    private var locationStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where are you\(store.profile.name.isEmpty ? "" : ", \(store.profile.name)")?")
                .font(RISE.F.display(28))
                .foregroundStyle(RISE.C.ink)
            Text("We'll find real opportunities in your community.")
                .font(RISE.F.body(15))
                .foregroundStyle(RISE.C.ink3)

            ForEach(Catalog.provinces, id: \.self) { prov in
                DisclosureGroup {
                    ForEach(Catalog.locations(in: prov)) { loc in
                        SelectRow(title: loc.label,
                                  selected: store.profile.locationId == loc.id) {
                            store.profile.locationId = loc.id
                        }
                    }
                } label: {
                    Text(prov)
                        .font(RISE.F.body(15, .semibold))
                        .foregroundStyle(RISE.C.ink)
                }
                .tint(RISE.C.fire)
                .padding(.vertical, 2)
            }
        }
    }

    private var talentStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What are your things?")
                .font(RISE.F.display(28))
                .foregroundStyle(RISE.C.ink)
            Text("Pick the area you'd most enjoy.")
                .font(RISE.F.body(15))
                .foregroundStyle(RISE.C.ink3)

            ForEach(Catalog.talents) { t in
                Button {
                    store.profile.talents = [t.id]
                    store.profile.capabilities = []   // capabilities belong to a talent
                    haptic()
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: t.symbol)
                            .font(.system(size: 17))
                            .foregroundStyle(store.profile.talents.contains(t.id) ? RISE.C.fire : RISE.C.ink4)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.label)
                                .font(RISE.F.body(15, .semibold))
                                .foregroundStyle(RISE.C.ink)
                            Text(t.blurb)
                                .font(RISE.F.body(12))
                                .foregroundStyle(RISE.C.ink3)
                        }
                        Spacer()
                        if store.profile.talents.contains(t.id) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(RISE.C.fire)
                        }
                    }
                    .padding(14)
                    .background(store.profile.talents.contains(t.id) ? RISE.C.ember : RISE.C.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(store.profile.talents.contains(t.id) ? RISE.C.fire : RISE.C.ink5,
                                      lineWidth: store.profile.talents.contains(t.id) ? 2 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var capabilityStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What can you actually do?")
                .font(RISE.F.display(28))
                .foregroundStyle(RISE.C.ink)
            Text("These are what we match on, so the more you select, the sharper your matches.")
                .font(RISE.F.body(15))
                .foregroundStyle(RISE.C.ink3)

            if let t = Catalog.talent(store.profile.talents.first ?? "") {
                ForEach(t.capabilities) { c in
                    SelectRow(title: c.text,
                              selected: store.profile.capabilities.contains(c.text),
                              multiline: true) {
                        toggle(c.text, in: &store.profile.capabilities)
                    }
                }
            }
        }
    }

    private var detailStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Last few things.")
                .font(RISE.F.display(28))
                .foregroundStyle(RISE.C.ink)

            group("AVAILABILITY") {
                ForEach(Catalog.availability, id: \.0) { id, label, sub in
                    SelectRow(title: label, subtitle: sub,
                              selected: store.profile.availability == label) {
                        store.profile.availability = label
                    }
                }
            }

            group("HOW YOU WANT TO SHOW UP") {
                ForEach(Catalog.showUp, id: \.0) { id, label, sub in
                    SelectRow(title: label, subtitle: sub,
                              selected: store.profile.showUp == id) {
                        store.profile.showUp = id
                    }
                }
            }

            group("WHO YOU'D LIKE TO SERVE") {
                ForEach(Catalog.serve, id: \.0) { id, label in
                    SelectRow(title: label, selected: store.profile.serve.contains(label)) {
                        toggle(label, in: &store.profile.serve)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("ANYTHING ELSE?")
                    .font(RISE.F.eyebrow).tracking(1.1).foregroundStyle(RISE.C.ink4)
                Text("In your own words. This is weighted highest of anything you tell us.")
                    .font(RISE.F.body(12)).foregroundStyle(RISE.C.ink3)
                TextEditor(text: $store.profile.detail)
                    .font(RISE.F.body(15))
                    .frame(height: 90)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RISE.C.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(RISE.C.ink5, lineWidth: 1.5))
            }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(RISE.F.eyebrow).tracking(1.1).foregroundStyle(RISE.C.ink4)
            content()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button("Back") { withAnimation { step -= 1 } }
                    .buttonStyle(GhostButtonStyle())
                    .frame(width: 110)
            }
            Button(step == steps - 1 ? "Find my matches" : "Continue") { advance() }
                .buttonStyle(FireButtonStyle())
                .disabled(!canAdvance)
                .opacity(canAdvance ? 1 : 0.5)
        }
        .padding(.horizontal, RISE.M.gutter)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }

    private var canAdvance: Bool {
        switch step {
        case 0: return store.profile.name.trimmingCharacters(in: .whitespaces).count >= 2
        case 1: return !store.profile.locationId.isEmpty
        case 2: return !store.profile.talents.isEmpty
        case 3: return !store.profile.capabilities.isEmpty
        default: return true
        }
    }

    private func advance() {
        guard canAdvance else { return }
        haptic()
        if step == steps - 1 {
            store.save()
            searching = true
            Task { await engine.search(profile: store.profile) }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { step += 1 }
        }
    }

    private func toggle(_ v: String, in arr: inout [String]) {
        if let i = arr.firstIndex(of: v) { arr.remove(at: i) } else { arr.append(v) }
        haptic()
    }

    private func haptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// A selectable row big enough to hit with a thumb without looking.
struct SelectRow: View {
    let title: String
    var subtitle: String? = nil
    var selected: Bool
    var multiline: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(RISE.F.body(multiline ? 14 : 15, .medium))
                        .foregroundStyle(RISE.C.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(RISE.F.body(12))
                            .foregroundStyle(RISE.C.ink3)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? RISE.C.fire : RISE.C.ink5)
                    .font(.system(size: 19))
            }
            .padding(13)
            .frame(minHeight: 48)          // comfortable touch target
            .background(selected ? RISE.C.ember : RISE.C.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? RISE.C.fire : RISE.C.ink5, lineWidth: selected ? 1.8 : 1))
        }
        .buttonStyle(.plain)
    }
}
