import Foundation
import TokenStatsCore

/// Codex: OAuth-Token aus `~/.codex/auth.json` → `chatgpt.com/backend-api/wham/usage`.
/// Wie bei Claude wird das Token nur gelesen, nie erneuert – das übernimmt die Codex-CLI.
struct CodexProvider: UsageProvider {
    let kind = "codex"
    let displayName = "Codex"
    let source: AccountSource

    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let hint = "Codex einmal starten oder »codex login«."

    /// `home` = `CODEX_HOME` eines weiteren Kontos; `nil` = Standardkonto `~/.codex`.
    init(home: URL? = nil, origin: AccountSource.Origin = .detected) {
        let folder = home?.standardizedFileURL
        var source = AccountSource(folder: folder, origin: folder == nil ? .standard : origin)
        let file = (folder ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")).appending(path: "auth.json")
        if let data = try? Data(contentsOf: file), let account = Self.parseAccount(data) {
            source.identity = account.id
            source.email = account.email
        }
        self.source = source
    }

    var id: String {
        guard let folder = source.folder else { return kind }
        return "\(kind)@\(FolderHash.of(folder.path))"
    }

    /// Ordner dieses Kontos; Logs liegen in `sessions` und `archived_sessions`.
    var homeDirectory: URL {
        source.folder ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    }

    private var authFile: URL { homeDirectory.appending(path: "auth.json") }

    private var loginHint: String {
        guard let folder = source.folderDisplay else { return Self.hint }
        return "»CODEX_HOME=\(folder) codex« einmal starten oder »… codex login«."
    }

    /// Kontokennung und E-Mail aus `auth.json` – für Bezeichnung und doppelte Anmeldungen.
    static func parseAccount(_ data: Data) -> (id: String?, email: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any]
        else { return nil }
        let id = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let email = (tokens["id_token"] as? String).flatMap(JWT.payload)?["email"] as? String
        return (id, email)
    }

    func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: authFile.path)
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let data = try? Data(contentsOf: authFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty
        else { throw ProviderError.notLoggedIn(hint: loginHint) }

        if let exp = JWT.payload(accessToken)?["exp"] as? Double, Date(timeIntervalSince1970: exp) < .now {
            throw ProviderError.tokenExpired(hint: loginHint)
        }

        var headers = ["Authorization": "Bearer \(accessToken)"]
        if let accountID = tokens["account_id"] as? String, !accountID.isEmpty {
            headers["chatgpt-account-id"] = accountID
        }
        let response = try await HTTP.getJSON(Self.usageURL, headers: headers, expiredHint: loginHint)
        var snapshot = try Self.parse(response)

        let claims = (tokens["id_token"] as? String).flatMap(JWT.payload)
        let auth = claims?["https://api.openai.com/auth"] as? [String: Any]
        let plan = (auth?["chatgpt_plan_type"] as? String) ?? snapshot.account?.plan
        snapshot.account = AccountInfo(
            name: claims?["email"] as? String,
            plan: plan.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        )
        return snapshot
    }

    // MARK: Antwort

    private struct Response: Decodable {
        struct Window: Decodable {
            var used_percent: Double?
            var reset_at: Double?
            var limit_window_seconds: Double?
        }
        struct RateLimit: Decodable {
            var primary_window: Window?
            var secondary_window: Window?
        }
        struct Additional: Decodable {
            var limit_name: String?
            var metered_feature: String?
            var rate_limit: RateLimit?
        }
        struct Credits: Decodable {
            var has_credits: Bool?
            var unlimited: Bool?
            var balance: String?
        }
        var plan_type: String?
        var rate_limit: RateLimit?
        var code_review_rate_limit: RateLimit?
        var additional_rate_limits: [Additional]?
        var credits: Credits?
    }

    static func parse(_ data: Data, now: Date = .now) throws -> ProviderSnapshot {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let rateLimit = response.rate_limit
        else { throw ProviderError.badResponse }

        func window(_ id: String, _ source: Response.Window?, name: String? = nil) -> LimitWindow? {
            guard let source, let used = source.used_percent else { return nil }
            let length = source.limit_window_seconds
            let (defaultName, note) = describe(length)
            return LimitWindow(
                id: id, name: name ?? defaultName, scopeNote: note,
                percent: used / 100,
                resetsAt: source.reset_at.map { Date(timeIntervalSince1970: $0) },
                windowLength: length
            )
        }

        // Neuere Antworten haben nur ein Wochenfenster in `primary_window`;
        // `describe` benennt es dann anhand der Fensterlänge richtig.
        var windows = [
            window("primary", rateLimit.primary_window),
            window("secondary", rateLimit.secondary_window),
            window("review", response.code_review_rate_limit?.primary_window, name: "Code-Review"),
        ].compactMap { $0 }

        for (index, extra) in (response.additional_rate_limits ?? []).enumerated() {
            let name = extra.limit_name ?? extra.metered_feature ?? "Weiteres Limit"
            if let primary = window("add-\(index)-p", extra.rate_limit?.primary_window, name: name) {
                windows.append(primary)
            }
            if let secondary = window("add-\(index)-s", extra.rate_limit?.secondary_window, name: name) {
                windows.append(secondary)
            }
        }

        var extras: [ExtraValue] = []
        if let credits = response.credits {
            if credits.unlimited == true {
                extras.append(ExtraValue(id: "credits", text: "Credits unbegrenzt"))
            } else if credits.has_credits == true, let balance = credits.balance.flatMap(Double.init) {
                extras.append(ExtraValue(id: "credits", text: "Credits \(Format.number(balance))"))
            }
        }

        return ProviderSnapshot(
            account: AccountInfo(name: nil, plan: response.plan_type),
            windows: windows, extras: extras, fetchedAt: now
        )
    }

    /// 18000 s → ("Session", "5 h"), 604800 s → ("Woche", "7 d")
    static func describe(_ seconds: Double?) -> (String, String?) {
        guard let seconds, seconds > 0 else { return ("Limit", nil) }
        let hours = seconds / 3600
        if hours >= 24 * 6 { return ("Woche", "\(Int((hours / 24).rounded())) d") }
        if hours >= 24 { return ("Tag", "\(Int((hours / 24).rounded())) d") }
        return ("Session", "\(Int(hours.rounded())) h")
    }
}
