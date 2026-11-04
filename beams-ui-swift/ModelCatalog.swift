import Foundation

/// Model IDs fetched from the provider's `GET /v1/models`, merged ahead of the
/// built-in lists in SettingsView. Asks the local agent proxy if it's enabled,
/// else a beam (whose shell has ANTHROPIC_BASE_URL / OPENAI_BASE_URL). The last
/// good list per agent is kept in UserDefaults for offline launches.
@MainActor
final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()

    @Published private(set) var fetched: [String: [String]] = [:]   // agent → ids
    @Published private(set) var fetchedAt: [String: Date] = [:]
    @Published private(set) var loading = false
    @Published private(set) var note = ""

    private init() {
        let d = UserDefaults.standard
        for agent in ["claude", "codex"] {
            if let ids = d.stringArray(forKey: Self.key(agent)) { fetched[agent] = ids }
            if let t = d.object(forKey: Self.key(agent) + ".at") as? Date { fetchedAt[agent] = t }
        }
    }

    private static func key(_ agent: String) -> String { "models.fetched.\(agent)" }

    /// Fetched IDs first (provider order), then any built-in IDs the API
    /// doesn't list (e.g. Claude Code's `[1m]` aliases).
    func models(for agent: String, builtIn: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for id in (fetched[agent] ?? []) + builtIn where seen.insert(id).inserted { out.append(id) }
        return out
    }

    func refresh(_ model: AppModel) async {
        guard !model.isMock, !loading else { return }
        let agent = model.config.agent
        loading = true
        defer { loading = false }
        var errors: [String] = []

        let port = model.config.agentProxyPort
        if model.config.agentProxyEnabled, port > 0 {
            do {
                save(agent, try await fetchLocal(agent: agent, port: port), source: "proxy on port \(port)")
                return
            } catch { errors.append("local proxy: \(Self.clean(error.localizedDescription))") }
        }
        if let beam = beamToAsk(model) {
            do {
                let res = try await model.client.run(id: beam.id, script: Self.listScript(agent: agent), timeout: 30)
                save(agent, try Self.parseIDs(res.stdout, agent: agent), source: "beam \(beam.name)")
                return
            } catch {
                let msg = Self.clean(error.localizedDescription)
                if Self.isExpiredLogin(msg) {
                    // Not a refused SSH login: don't record it as one (that would
                    // block every beam action). Re-check so the login banner shows.
                    _ = await model.checkTsh()
                    errors.append("Teleport login expired. Log in again, then click Refresh models")
                } else {
                    model.noteSSHFailure(msg)
                    errors.append("beam \(beam.name): \(msg)")
                }
            }
        }
        note = errors.isEmpty ? "No beam or local proxy to ask; showing the built-in list." : errors.joined(separator: " · ")
    }

    private func save(_ agent: String, _ ids: [String], source: String) {
        fetched[agent] = ids
        fetchedAt[agent] = Date()
        UserDefaults.standard.set(ids, forKey: Self.key(agent))
        UserDefaults.standard.set(Date(), forKey: Self.key(agent) + ".at")
        note = "\(ids.count) models from \(source)"
    }

    /// The current session's beam if it's alive, else any beam. Never connects
    /// when this login can't SSH into beams (each try is a failed audit login).
    private func beamToAsk(_ model: AppModel) -> Beam? {
        guard model.tsh.loggedIn, model.sshBlockedReason == nil else { return nil }
        if let s = model.current, !s.isLocal, let b = model.beams.first(where: { $0.id == s.beamId }) { return b }
        return model.beams.first
    }

    private func fetchLocal(agent: String, port: Int) async throws -> [String] {
        let path = agent == "codex" ? "/v1/models" : "/v1/models?limit=1000"
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw ModelListError("bad port \(port)") }
        var req = URLRequest(url: url, timeoutInterval: 15)
        if agent == "codex" {
            req.setValue("Bearer dummy", forHTTPHeaderField: "Authorization")
        } else {
            // Same dummy key pi uses; the Teleport app proxy supplies real auth.
            req.setValue("dummy", forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw ModelListError(http.statusCode == 404 ? "HTTP 404 (the proxied app doesn't serve /v1/models)" : "HTTP \(http.statusCode)")
        }
        return try Self.parseIDs(data, agent: agent)
    }

    /// One line, no terminal color codes (tsh colors its ERROR prefix).
    nonisolated static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"\u{1B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// tsh's certificate ran out after the last login check.
    nonisolated static func isExpiredLogin(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("cert has expired") || l.contains("certificate has expired") || l.contains("expired certificate")
    }

    /// Runs in the beam. Keys stay in the beam's environment; only the list comes back.
    nonisolated static func listScript(agent: String) -> String {
        if agent == "codex" {
            return """
            base="${OPENAI_BASE_URL:-https://api.openai.com/v1}"
            base="${base%/}"
            case "$base" in */v1) ;; *) base="$base/v1" ;; esac
            set -- -fsS --max-time 20
            [ -n "${OPENAI_API_KEY:-}" ] && set -- "$@" -H "authorization: Bearer $OPENAI_API_KEY"
            exec curl "$@" "$base/models"
            """
        }
        return """
        base="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
        set -- -fsS --max-time 20 -H 'anthropic-version: 2023-06-01'
        [ -n "${ANTHROPIC_API_KEY:-}" ] && set -- "$@" -H "x-api-key: $ANTHROPIC_API_KEY"
        [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] && set -- "$@" -H "authorization: Bearer $ANTHROPIC_AUTH_TOKEN"
        exec curl "$@" "${base%/}/v1/models?limit=1000"
        """
    }

    /// Both APIs answer `{"data":[{"id":…}, …]}`. Keeps chat/coding models only.
    nonisolated static func parseIDs(_ data: Data, agent: String) throws -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["data"] as? [[String: Any]] else {
            let body = String(decoding: data.prefix(160), as: UTF8.self)
            throw ModelListError("unexpected response: \(Secrets.redact(body))")
        }
        let ids = rows.compactMap { $0["id"] as? String }.filter { agent == "codex" ? isCodexModel($0) : $0.hasPrefix("claude-") }
        guard !ids.isEmpty else { throw ModelListError("no models in response") }
        return ids
    }

    nonisolated static func isCodexModel(_ id: String) -> Bool {
        let s = id.lowercased()
        let skip = ["embedding", "tts", "whisper", "dall-e", "audio", "realtime", "image", "moderation", "transcribe", "search"]
        if skip.contains(where: s.contains) { return false }
        return s.hasPrefix("gpt-") || s.contains("codex") || s.firstMatch(of: #/^o\d/#) != nil
    }
}

struct ModelListError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
