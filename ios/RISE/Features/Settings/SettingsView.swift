import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var showClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Your goal") {
                    Stepper(value: $store.goalHours, in: 10...200, step: 5) {
                        HStack {
                            Text("Hours target")
                            Spacer()
                            Text("\(Int(store.goalHours))")
                                .foregroundStyle(RISE.C.ink3).monospacedDigit()
                        }
                    }
                    .onChange(of: store.goalHours) { _, _ in store.save() }
                    Text("Ontario's OSSD requirement is 40 hours. Other provinces differ — set what yours asks for.")
                        .font(RISE.F.body(12))
                        .foregroundStyle(RISE.C.ink3)
                }

                Section("Saved opportunities") {
                    if store.saved.isEmpty {
                        Text("Nothing saved yet.")
                            .foregroundStyle(RISE.C.ink3)
                    } else {
                        ForEach(store.saved) { o in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.title).font(RISE.F.body(15, .medium))
                                Text(o.org).font(RISE.F.body(12)).foregroundStyle(RISE.C.ink3)
                            }
                        }
                        .onDelete { idx in
                            store.saved.remove(atOffsets: idx)
                            store.save()
                        }
                    }
                }

                Section("Matching") {
                    HStack {
                        Text("Live matching")
                        Spacer()
                        switch store.serverLive {
                        case .some(true):
                            Label("On", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(RISE.C.success)
                        case .some(false):
                            Label("Off", systemImage: "xmark.circle.fill")
                                .foregroundStyle(RISE.C.ink3)
                        case nil:
                            ProgressView().controlSize(.small)
                        }
                    }
                    Text("When live matching is off, RISE shows real organizations from its built-in library instead of searching. It will always tell you which you're looking at.")
                        .font(RISE.F.body(12))
                        .foregroundStyle(RISE.C.ink3)
                }

                Section("Your data") {
                    Text("Everything you enter stays on this device. RISE does not upload your name, answers or hours.")
                        .font(RISE.F.body(12))
                        .foregroundStyle(RISE.C.ink3)
                    Button("Delete everything", role: .destructive) { showClear = true }
                }

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(RISE.C.ink3)
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Delete everything?", isPresented: $showClear) {
                Button("Delete", role: .destructive) {
                    store.profile = StudentProfile()
                    store.entries = []
                    store.saved = []
                    store.save()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your profile, logged hours and saved opportunities will be removed from this device. This cannot be undone.")
            }
        }
    }
}
