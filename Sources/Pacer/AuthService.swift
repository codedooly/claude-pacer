import Foundation

/// Claude Code 인증 브리지 — `claude auth status`(상태 조회)·`claude auth login`(브라우저 OAuth).
/// Pacer 는 토큰을 저장하지 않고 Claude Code(Keychain)에 위임 — 여기서는 로그인 유발·상태 확인만 한다.
enum AuthService {
    struct Status { let loggedIn: Bool; let email: String?; let plan: String? }

    /// `claude auth status` → JSON 파싱. 실패·미로그인 시 loggedIn=false.
    static func status() async -> Status {
        let out = await runAuth(["auth", "status"], timeout: 30)
        // 경고 등 앞부분 노이즈 제거 — 첫 '{' 부터 JSON 파싱
        guard let start = out.firstIndex(of: "{"),
              let data = String(out[start...]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return Status(loggedIn: false, email: nil, plan: nil) }
        return Status(
            loggedIn: obj["loggedIn"] as? Bool ?? false,
            email: obj["email"] as? String,
            plan: obj["subscriptionType"] as? String)
    }

    /// `claude auth login` 실행 — claude 가 브라우저 OAuth 를 띄우고 로컬 콜백까지 처리한다.
    /// 프로세스 종료(로그인 완료/취소)까지 대기 후 status 로 성공 확인.
    /// @returns 로그인 성공 여부
    static func login() async -> Bool {
        // --claudeai: 구독(Claude.ai) 흐름 고정 — 계정유형 프롬프트 회피
        _ = await runAuth(["auth", "login", "--claudeai"], timeout: 180)
        return await status().loggedIn
    }

    /// claude 서브커맨드 실행 — 로그인 셸 env 흡수(RoutineService 공유), stdout+stderr 합쳐 반환.
    /// @param args claude 인자 (예: ["auth","status"])
    /// @param timeout 초 단위 강제 종료 한도
    private static func runAuth(_ args: [String], timeout: TimeInterval) async -> String {
        let p = Process()
        let claudePath = PingRunner.claudePath()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.arguments = args
        // GUI(.app) 최소 env 보강 — 로그인 셸 env(node·PATH) 흡수
        var env = RoutineService.loginShellEnv ?? ProcessInfo.processInfo.environment
        let claudeDir = (claudePath as NSString).deletingLastPathComponent
        let shellPath = env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = shellPath.contains(claudeDir) ? shellPath : "\(claudeDir):\(shellPath)"
        p.environment = env
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        // 종료까지 비동기 대기 (login 은 브라우저 인증까지 수십 초~수 분)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let lock = NSLock()
            var resumed = false
            func resumeOnce() {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                c.resume()
            }
            p.terminationHandler = { _ in resumeOnce() }
            do { try p.run() } catch { resumeOnce(); return }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if p.isRunning { p.terminate() }
                resumeOnce()
            }
        }

        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        return (String(data: o, encoding: .utf8) ?? "") + (String(data: e, encoding: .utf8) ?? "")
    }
}
