import Foundation

/// 5시간/7일 창 한 칸.
struct UsageWindow {
    let pct: Int
    let resetsAt: Date?
}

/// 주간 모델별(scoped) 한도 한 칸 — 예: Fable 전용 주간 쿼터. (API limits[].weekly_scoped)
struct ScopedLimit {
    let name: String    // 모델 표시명 (API scope.model.display_name — 예: "Fable")
    let pct: Int
    let resetsAt: Date? // 미사용이면 null
}

/// usage API 응답 정규화 결과.
struct Usage {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let weeklyScoped: [ScopedLimit]   // 주간 모델별 한도(Fable 등). limits 배열 기반 — 모델 늘면 자동 반영
}

enum UsageError: Error, CustomStringConvertible {
    case noToken
    case http(Int)
    case network(String)
    case decode

    var description: String {
        switch self {
        case .noToken: return "no-token"
        case .http(let c): return c == 429 ? "rate limited — retry shortly" : "http-\(c)"
        case .network(let m): return "net-\(m)"
        case .decode: return "decode"
        }
    }
}

/// macOS Keychain 의 Claude Code OAuth 토큰으로 Anthropic usage API 를 조회한다.
/// (usage.py 포팅. /api/oauth/usage 는 비공식 엔드포인트라 변경될 수 있음.)
struct UsageService {
    static let keychainService = "Claude Code-credentials"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let oauthBeta = "oauth-2025-04-20"

    /// Keychain 의 claudeAiOauth dict (token / subscriptionType 공통 소스).
    /// `refresh()` 가 한 번 읽어 token·plan·authed·fetch 로 전달하면 `security` 서브프로세스 1회로 끝남.
    func oauthDict() -> [String: Any]? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", Self.keychainService, "-w"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["claudeAiOauth"] as? [String: Any]
    }

    /// access token (이미 읽어둔 dict 재사용 가능).
    func token(from dict: [String: Any]? = nil) -> String? {
        (dict ?? oauthDict())?["accessToken"] as? String
    }

    /// Claude Code 인증 토큰 존재 여부 (온보딩 분기용).
    func hasCredentials(from dict: [String: Any]? = nil) -> Bool { token(from: dict) != nil }

    /// 구독 플랜 + 등급 — rateLimitTier 기반 ("Max 5x" / "Max 20x" / "Pro").
    func plan(from dict: [String: Any]? = nil) -> String? {
        guard let d = dict ?? oauthDict() else { return nil }
        let tier = (d["rateLimitTier"] as? String) ?? ""
        if tier.contains("max_20x") { return "Max (20x)" }
        if tier.contains("max_5x") { return "Max (5x)" }
        if tier.contains("pro") { return "Pro" }
        if tier.contains("free") { return "Free" }
        // 폴백: subscriptionType ("max" → "Max")
        if let sub = d["subscriptionType"] as? String { return sub.capitalized }
        return nil
    }

    /// usage API 호출 → 정규화된 Usage.
    func fetch(from dict: [String: Any]? = nil) async -> Result<Usage, UsageError> {
        guard let tok = token(from: dict) else { return .failure(.noToken) }

        var req = URLRequest(url: Self.usageURL)
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.oauthBeta, forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                return .failure(.http(http.statusCode))
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.decode)
            }
            return .success(Self.parse(obj))
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// API 응답 → {five_hour, seven_day, weeklyScoped}.
    /// 세션·주간은 데스크탑 앱과 동일하게 `limits` 배열을 우선 사용(값 불일치 방지), 없으면 구 top-level 필드로 폴백.
    static func parse(_ obj: [String: Any]) -> Usage {
        let limits = obj["limits"] as? [[String: Any]] ?? []

        // limits 배열에서 kind 로 창 찾기 (percent·resets_at) — 데스크탑 앱과 같은 소스
        func limitWindow(_ kind: String) -> UsageWindow? {
            guard let l = limits.first(where: { ($0["kind"] as? String) == kind }) else { return nil }
            let pct = (l["percent"] as? NSNumber)?.intValue ?? 0
            return UsageWindow(pct: pct, resetsAt: parseReset(l["resets_at"]))
        }
        // 구 top-level 필드(five_hour/seven_day) — limits 없을 때만 폴백
        func legacyWindow(_ key: String) -> UsageWindow? {
            guard
                let w = obj[key] as? [String: Any],
                let util = w["utilization"] as? NSNumber
            else { return nil }
            return UsageWindow(pct: Int(util.doubleValue.rounded()), resetsAt: parseReset(w["resets_at"]))
        }

        // 주간 모델별 scoped 한도(Fable 등) — limits 배열에서 추출. 모델명은 응답에 박혀 나옴(하드코딩 X)
        var scoped: [ScopedLimit] = []
        for l in limits where (l["kind"] as? String) == "weekly_scoped" {
            let name = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            let pct = (l["percent"] as? NSNumber)?.intValue ?? 0
            scoped.append(ScopedLimit(name: name ?? "Model", pct: pct, resetsAt: parseReset(l["resets_at"])))
        }

        return Usage(
            fiveHour: limitWindow("session") ?? legacyWindow("five_hour"),
            sevenDay: limitWindow("weekly_all") ?? legacyWindow("seven_day"),
            weeklyScoped: scoped
        )
    }

    /// epoch(Number) 또는 ISO8601(String) → Date.
    static func parseReset(_ value: Any?) -> Date? {
        if let n = value as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        if let s = value as? String {
            let withFrac = ISO8601DateFormatter()
            withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return withFrac.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        return nil
    }
}
