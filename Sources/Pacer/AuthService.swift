import Foundation

/// Claude Code 인증 브리지 — `claude auth status`(상태 조회)·`claude auth login`(브라우저 OAuth).
/// Pacer 는 토큰을 저장하지 않고 Claude Code(Keychain)에 위임 — 여기서는 로그인 유발·상태 확인만 한다.
/// 프로세스 실행·env 보강은 ClaudeCLI 공유.
enum AuthService {
    struct Status { let loggedIn: Bool; let email: String?; let plan: String? }

    /// 진행 중인 login 프로세스 — 취소(cancelLogin)용. 락으로 보호 (login 종료 vs cancel 경쟁).
    private static let lock = NSLock()
    private static var loginProcess: Process?

    /// `claude auth status` → JSON 파싱. 실패·미로그인 시 loggedIn=false.
    static func status() async -> Status {
        let claudePath = PingRunner.claudePath()
        let r = await ClaudeCLI.run(executable: claudePath, args: ["auth", "status"],
                                    env: ClaudeCLI.env(for: claudePath), timeout: 30)
        // 경고 등 앞부분 노이즈 제거 — 첫 '{' 부터 JSON 파싱
        guard let start = r.output.firstIndex(of: "{"),
              let data = String(r.output[start...]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return Status(loggedIn: false, email: nil, plan: nil) }
        return Status(
            loggedIn: obj["loggedIn"] as? Bool ?? false,
            email: obj["email"] as? String,
            plan: obj["subscriptionType"] as? String)
    }

    /// `claude auth login` 실행 — 출력에 찍히는 OAuth URL 을 onURL 로 전달(자동 열기 X — claude 자체 열기와 중복 방지).
    /// 프로세스 종료(콜백 완료/취소)까지 대기 후 status 로 성공 확인.
    /// @param onURL claude 가 출력한 OAuth URL 콜백 (UI 에 클릭 링크로 노출)
    /// @returns 로그인 성공 여부
    static func login(onURL: @escaping (URL) -> Void) async -> Bool {
        let claudePath = PingRunner.claudePath()

        // 출력서 첫 https URL 1회만 추출 — 증분 콜백
        let urlLock = NSLock()
        var reported = false
        let scan: (FileHandle) -> Void = { fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) else { return }
            urlLock.lock(); defer { urlLock.unlock() }
            guard !reported,
                  let r = s.range(of: "https://\\S+", options: .regularExpression),
                  let url = URL(string: String(s[r])) else { return }
            reported = true
            onURL(url)
        }

        // --claudeai: 구독(Claude.ai) 흐름 고정 — 계정유형 프롬프트 회피
        _ = await ClaudeCLI.run(
            executable: claudePath, args: ["auth", "login", "--claudeai"],
            env: ClaudeCLI.env(for: claudePath), timeout: 180,
            onStart: { p in lock.lock(); loginProcess = p; lock.unlock() },
            onChunk: scan)
        lock.lock(); loginProcess = nil; lock.unlock()
        return await status().loggedIn
    }

    /// 진행 중인 login 취소 — 프로세스 종료 (사용자가 브라우저를 닫았거나 그만둘 때).
    static func cancelLogin() {
        lock.lock(); let p = loginProcess; loginProcess = nil; lock.unlock()
        p?.terminate()
    }
}
