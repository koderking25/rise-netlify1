import SwiftUI

struct HoursView: View {
    @EnvironmentObject var store: Store
    @State private var adding = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ring
                    if store.entries.isEmpty { empty } else { list }
                }
                .padding(.horizontal, RISE.M.gutter)
                .padding(.bottom, 40)
            }
            .background(RISE.C.canvas)
            .navigationTitle("My hours")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Log hours")
                }
            }
            .sheet(isPresented: $adding) { LogHoursSheet() }
        }
    }

    private var ring: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(RISE.C.ink6, lineWidth: 14)
                Circle()
                    .trim(from: 0, to: store.progress)
                    .stroke(LinearGradient(colors: [RISE.C.fire, RISE.C.fireLight],
                                           startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.7, dampingFraction: 0.8), value: store.progress)
                VStack(spacing: 0) {
                    Text("\(store.totalHours, specifier: "%.1f")")
                        .font(RISE.F.display(44))
                        .foregroundStyle(RISE.C.ink)
                        .monospacedDigit()
                    Text("of \(Int(store.goalHours)) hours")
                        .font(RISE.F.body(13))
                        .foregroundStyle(RISE.C.ink3)
                }
            }
            .frame(width: 190, height: 190)
            .padding(.top, 8)

            if store.progress >= 1 {
                Label("Goal reached", systemImage: "checkmark.seal.fill")
                    .font(RISE.F.body(14, .semibold))
                    .foregroundStyle(RISE.C.success)
            }
        }
        .frame(maxWidth: .infinity)
        .riseCard()
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 32))
                .foregroundStyle(RISE.C.ink4)
            Text("No hours logged yet")
                .font(RISE.F.body(16, .semibold))
                .foregroundStyle(RISE.C.ink)
            Text("Log a session after you volunteer and it counts toward your goal.")
                .font(RISE.F.body(13))
                .foregroundStyle(RISE.C.ink3)
                .multilineTextAlignment(.center)
            Button("Log your first hours") { adding = true }
                .buttonStyle(FireButtonStyle())
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .riseCard()
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR LOG")
                .font(RISE.F.eyebrow).tracking(1.1).foregroundStyle(RISE.C.ink4)
            ForEach(store.entries) { e in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Text("\(e.hours, specifier: "%.1f")")
                            .font(RISE.F.body(17, .bold)).monospacedDigit()
                            .foregroundStyle(RISE.C.fire)
                        Text("hrs").font(RISE.F.body(10)).foregroundStyle(RISE.C.ink4)
                    }
                    .frame(width: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.org)
                            .font(RISE.F.body(15, .semibold))
                            .foregroundStyle(RISE.C.ink)
                        if !e.role.isEmpty {
                            Text(e.role).font(RISE.F.body(12)).foregroundStyle(RISE.C.ink3)
                        }
                        Text(e.date, style: .date)
                            .font(RISE.F.body(11))
                            .foregroundStyle(RISE.C.ink4)
                    }
                    Spacer()
                    // Present but never set by the app — see HourEntry. A school
                    // accepts a record a supervisor stands behind, and this is
                    // where that will show once sign-off exists.
                    if e.verified {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(RISE.C.success)
                            .accessibilityLabel("Verified by supervisor")
                    }
                }
                .riseCard(padding: 13)
            }
        }
    }
}

struct LogHoursSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var org = ""
    @State private var role = ""
    @State private var date = Date()
    @State private var hours = 2.0

    var body: some View {
        NavigationStack {
            Form {
                Section("What you did") {
                    TextField("Organization", text: $org)
                    TextField("Role (optional)", text: $role)
                }
                Section("When") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Stepper(value: $hours, in: 0.5...12, step: 0.5) {
                        Text("\(hours, specifier: "%.1f") hours").monospacedDigit()
                    }
                }
                Section {
                    Text("Keep this honest — it's a record you may show a school.")
                        .font(RISE.F.body(12))
                        .foregroundStyle(RISE.C.ink3)
                }
            }
            .navigationTitle("Log hours")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.addEntry(HourEntry(org: org, role: role, date: date, hours: hours))
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        dismiss()
                    }
                    .disabled(org.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
