import SwiftUI

@main
struct RISEApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(RISE.C.fire)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView(goToMatch: { tab = 1 })
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            MatchFlowView()
                .tabItem { Label("Match", systemImage: "sparkles") }
                .tag(1)

            HoursView()
                .tabItem { Label("Hours", systemImage: "clock.fill") }
                .tag(2)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .task { await store.checkServer() }
    }
}

/// App-wide state. Persisted to disk as JSON rather than to a server, because
/// the app is useful signed-out and nothing here needs an account to work.
@MainActor
final class Store: ObservableObject {
    @Published var profile = StudentProfile()
    @Published var entries: [HourEntry] = []
    @Published var saved: [Opportunity] = []
    @Published var goalHours: Double = 40
    @Published var serverLive: Bool?      // nil = not checked yet

    private let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() { load() }

    var totalHours: Double { entries.reduce(0) { $0 + $1.hours } }
    var progress: Double { goalHours <= 0 ? 0 : min(totalHours / goalHours, 1) }

    func checkServer() async {
        let p = await AIClient.shared.ping()
        serverLive = (p?.ok == true) && (p?.search == true)
    }

    // MARK: - Persistence

    func save() {
        write(profile, "profile.json")
        write(entries, "entries.json")
        write(saved, "saved.json")
        write(goalHours, "goal.json")
    }

    private func load() {
        profile = read(StudentProfile.self, "profile.json") ?? StudentProfile()
        entries = read([HourEntry].self, "entries.json") ?? []
        saved = read([Opportunity].self, "saved.json") ?? []
        goalHours = read(Double.self, "goal.json") ?? 40
    }

    private func write<T: Encodable>(_ value: T, _ name: String) {
        guard let d = try? JSONEncoder().encode(value) else { return }
        try? d.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }

    // MARK: - Mutations

    func toggleSaved(_ o: Opportunity) {
        if let i = saved.firstIndex(where: { $0.id == o.id }) { saved.remove(at: i) }
        else { saved.append(o) }
        save()
    }

    func isSaved(_ o: Opportunity) -> Bool { saved.contains { $0.id == o.id } }

    func addEntry(_ e: HourEntry) {
        entries.insert(e, at: 0)
        save()
    }

    func deleteEntries(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
    }
}
