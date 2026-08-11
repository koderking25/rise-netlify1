import SwiftUI

/// Drafts the first email and hands it to the system mail composer.
///
/// The draft is editable before it goes anywhere. That matters more here than
/// on the web: this is a minor writing to an adult stranger, and the app should
/// never be the thing that sends it. RISE writes, the student reads and sends.
struct OutreachSheet: View {
    let opp: Opportunity
    let profile: StudentProfile
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    VStack(spacing: 14) {
                        ProgressView().tint(RISE.C.fire)
                        Text("Writing your first email…")
                            .font(RISE.F.body(14))
                            .foregroundStyle(RISE.C.ink3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if let error {
                                Text(error)
                                    .font(RISE.F.body(13))
                                    .foregroundStyle(RISE.C.danger)
                            }
                            Text("To: \(opp.contactEmail ?? opp.org)")
                                .font(RISE.F.body(13, .medium))
                                .foregroundStyle(RISE.C.ink3)

                            TextEditor(text: $draft)
                                .font(RISE.F.body(15))
                                .frame(minHeight: 300)
                                .scrollContentBackground(.hidden)
                                .padding(10)
                                .background(RISE.C.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(RISE.C.ink5, lineWidth: 1))

                            Text("Read it before you send. Change anything that doesn't sound like you.")
                                .font(RISE.F.body(12))
                                .foregroundStyle(RISE.C.ink3)
                        }
                        .padding(RISE.M.gutter)
                    }
                }
            }
            .background(RISE.C.canvas)
            .navigationTitle("Your email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Opens the mail app with the draft loaded. The student
                    // presses send, not RISE.
                    Button {
                        openMail()
                    } label: { Label("Open in Mail", systemImage: "envelope") }
                        .disabled(draft.isEmpty)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            draft = try await AIClient.shared.draftOutreach(opp: opp, profile: profile)
        } catch {
            // A failed draft should not be a dead end — give them a usable
            // skeleton they can finish themselves.
            self.error = "Couldn't reach the writing service, so here's a starting point."
            draft = """
            Hi,

            I'm \(profile.name.isEmpty ? "a high-school student" : profile.name), and I'd like to volunteer with \(opp.org).

            \(profile.capabilities.first ?? "I'd like to help where I can.")

            Is the \(opp.title) role still open, and what would the next step be?

            Thanks,
            \(profile.name)
            """
        }
        loading = false
    }

    private func openMail() {
        let to = opp.contactEmail ?? ""
        let subject = "Volunteering — \(opp.title)"
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = to
        c.queryItems = [URLQueryItem(name: "subject", value: subject),
                        URLQueryItem(name: "body", value: draft)]
        if let url = c.url { UIApplication.shared.open(url) }
    }
}
