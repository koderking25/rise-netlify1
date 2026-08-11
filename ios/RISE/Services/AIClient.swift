import Foundation

/// Talks to the same Cloudflare Worker the web app uses.
///
/// This is the whole reason the iOS app needs no Anthropic key of its own.
/// An API key shipped inside an iOS binary is not secret — the binary is a zip
/// anyone can download from the App Store and `strings` — so the key stays in
/// the Worker's environment and the app only ever calls `/api/ai-search`.
/// It also means the server-side cohort cache, spend cap, rate limiting and
/// link verification apply to iOS traffic for free, and any prompt improvement
/// lands on both clients at once.
///
/// Set `baseURL` to your deployed Worker before shipping.
actor AIClient {
    static let shared = AIClient()

    /// CHANGE ME before archiving: your deployed Worker origin.
    /// e.g. "https://rise-netlify1.<subdomain>.workers.dev"
    static let baseURL = URL(string: "https://rise-netlify1.workers.dev")!

    private var path: URL { Self.baseURL.appendingPathComponent("api/ai-search") }

    enum AIError: LocalizedError {
        case noProvider
        case budget(String)
        case http(Int, String)
        case decoding
        case offline

        var errorDescription: String? {
            switch self {
            case .noProvider:   return "Live matching isn't configured on the server yet."
            case .budget(let m): return m
            case .http(let c, let m):
                return m.isEmpty ? "The matching server returned \(c)." : m
            case .decoding:     return "The matching server sent something unreadable."
            case .offline:      return "You're offline — showing saved organizations."
            }
        }
    }

    // MARK: - Capability probe

    struct Ping: Decodable { let ok: Bool; let provider: String?; let search: Bool? }

    /// Cheap, token-free check of what the server can actually do. Called once
    /// at launch so the UI can tell the student the truth up front rather than
    /// promising live matching and quietly serving the offline library.
    func ping() async -> Ping? {
        var req = URLRequest(url: path)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "ping"])
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONDecoder().decode(Ping.self, from: data)
    }

    // MARK: - Discovery

    /// The shared, impersonal pass — "what roles for this category exist in
    /// this place?" Identical for every student in the cohort, so it carries a
    /// `cacheKey` and the Worker serves it from cache after the first student
    /// pays for it. Nothing personal may go in this request.
    func discover(talent: Talent, location: RLocation, angle: Int, remoteOnly: Bool) async throws -> [Opportunity] {
        let key = "disc:v1:\(location.id):\(talent.id):\(angle % 4):\(remoteOnly ? "r" : "l")"
        let body: [String: Any] = [
            "model": "claude-sonnet-5",
            "system": Prompts.system,
            "max_tokens": 3600,
            "temperature": 0.3,
            "schema": Prompts.oppSchema,
            "cacheKey": key,
            "search": ["maxUses": 4, "country": "CA",
                       "city": location.short, "region": location.province],
            "messages": [["role": "user",
                          "content": Prompts.discovery(talent: talent, location: location,
                                                       angle: angle, remoteOnly: remoteOnly)]]
        ]
        let res = try await post(body, timeout: 90)
        return Self.parseOpportunities(res)
    }

    /// The personal pass — scores a candidate pool against one student. Never
    /// cached, because the answer is different for every person.
    func judge(pool: [Opportunity], profile: StudentProfile,
               talent: Talent, location: RLocation) async throws -> [Int: JudgeVerdict] {
        let body: [String: Any] = [
            "model": "claude-sonnet-5",
            "system": Prompts.system,
            "max_tokens": 3000,
            "temperature": 0.1,
            "schema": Prompts.judgeSchema,
            "messages": [["role": "user",
                          "content": Prompts.judge(pool: pool, profile: profile,
                                                   talent: talent, location: location)]]
        ]
        let res = try await post(body, timeout: 75)
        var out: [Int: JudgeVerdict] = [:]
        for item in Self.parsedArray(res) {
            guard let id = item["id"] as? Int else { continue }
            out[id] = JudgeVerdict(
                capability: item["capability"] as? Int,
                population: item["population"] as? Int,
                logistics: item["logistics"] as? Int,
                credibility: item["credibility"] as? Int,
                total: item["total"] as? Int,
                evidence: item["evidence"] as? String,
                verdict: item["verdict"] as? String
            )
        }
        return out
    }

    /// Drafts the outreach email. Kept server-side like everything else so the
    /// prompt can be improved without shipping a new build through review.
    func draftOutreach(opp: Opportunity, profile: StudentProfile) async throws -> String {
        let body: [String: Any] = [
            "model": "claude-sonnet-5",
            "max_tokens": 700,
            "temperature": 0.6,
            "system": "You write short, plain, sincere emails for a teenager approaching a volunteer coordinator. No corporate voice, no flattery, no em-dashes. Six sentences at most.",
            "messages": [["role": "user", "content": Prompts.outreach(opp: opp, profile: profile)]]
        ]
        let res = try await post(body, timeout: 45)
        return Self.plainText(res)
    }

    // MARK: - Link verification

    /// A phone can't read cross-origin status codes any more than a browser
    /// can, so the Worker checks the links and reports which resolve.
    func verify(urls: [String]) async -> [String: Bool] {
        guard !urls.isEmpty else { return [:] }
        let body: [String: Any] = ["action": "verify", "urls": Array(urls.prefix(24))]
        guard let res = try? await post(body, timeout: 20),
              let results = res["results"] as? [String: Any] else { return [:] }
        var out: [String: Bool] = [:]
        for (url, v) in results {
            if let d = v as? [String: Any], let ok = d["ok"] as? Bool { out[url] = ok }
        }
        return out
    }

    // MARK: - Transport

    private func post(_ body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        var req = URLRequest(url: path)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch { throw AIError.offline }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        guard code == 200 else {
            let msg = (json["error"] as? String) ?? ""
            // The Worker returns 429 with a plain explanation when the daily
            // spend cap is reached. Pass that through verbatim; it is a real
            // answer, not a fault the student should see as a crash.
            if code == 429 { throw AIError.budget(msg.isEmpty ? "Daily matching limit reached — try again tomorrow." : msg) }
            if msg.lowercased().contains("no provider key") { throw AIError.noProvider }
            throw AIError.http(code, msg)
        }
        return json
    }

    // MARK: - Response parsing

    /// The Worker returns either a `parsed` array (the model called the emit
    /// tool) or prose we salvage JSON from. Both paths are handled because the
    /// model occasionally answers in text even when a tool is offered, and the
    /// request costs the same either way.
    private static func parsedArray(_ res: [String: Any]) -> [[String: Any]] {
        if let parsed = res["parsed"] as? [[String: Any]] { return parsed }
        if let parsed = res["parsed"] as? [String: Any],
           let items = parsed["items"] as? [[String: Any]] { return items }
        let text = plainText(res)
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]") else { return [] }
        let slice = String(text[start...end])
        guard let d = slice.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
        return arr
    }

    private static func plainText(_ res: [String: Any]) -> String {
        guard let content = res["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                      .joined(separator: "\n")
    }

    private static func parseOpportunities(_ res: [String: Any]) -> [Opportunity] {
        let arr = parsedArray(res)
        guard let data = try? JSONSerialization.data(withJSONObject: arr) else { return [] }
        var opps = (try? JSONDecoder().decode([Opportunity].self, from: data)) ?? []
        for i in opps.indices { opps[i].origin = "web" }
        return opps
    }
}
