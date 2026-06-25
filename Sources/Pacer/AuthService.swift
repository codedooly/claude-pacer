import Foundation

/// Claude Code 인증 브리지 — `claude auth status`(상태 조회)·`claude auth login`(브라우저 OAuth).
/// Pacer 는 토큰을 저장하지 않고 Claude Code(Keychain)에 위임 — 여기서는 로그인 유발·상태 확인만 한다.
enum AuthService {
    struct Status { let loggedIn: Bool; let email: String?; let plan: String? }

    /// 진행 중인 login 프로세스 — 취소(cancelLogin)용.
    private static var loginProcess: Process?

    /// `claude auth status` → JSON 파싱. 실패·미로그인 시 loggedIn=false.
    static func status() async -> Status {
        let out = await runStatus()
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

    /// `claude auth login` 실행 — 출력에 찍히는 OAuth URL 을 Pacer 가 직접 브라우저로 연다.
    /// (.app 컨텍스트에선 claude 자체의 브라우저 자동 열기가 안 될 수 있어(jisu) 우리가 연다.)
    /// 프로세스 종료(콜백 완료/취소)까지 대기 후 status 로 성공 확인.
    /// @returns 로그인 성공 여부
    /// @param onURL claude 가 출력한 OAuth URL 을 UI 에 노출하는 콜백 (자동 열기 X — claude 자체 열기와 중복 방지)
    static func login(onURL: @escaping (URL) -> Void) async -> Bool {
        let p = Process()
        loginProcess = p
        let claudePath = PingRunner.claudePath()
        p.executableURL = URL(fileURLWithPath: claudePath)
        // --claudeai: 구독(Claude.ai) 흐름 고정 — 계정유형 프롬프트 회피
        p.arguments = ["auth", "login", "--claudeai"]
        p.environment = claudeEnv(claudePath)
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        // stdout·stderr 증분 읽기 — 초반에 찍히는 OAuth URL 을 잡아 UI 에 링크로 전달 (1회).
        // 직접 열지 않는 이유: claude 가 보통 자동으로 열어서, 우리가 또 열면 브라우저 창이 2개 뜬다.
        // claude 자동 열기가 안 되는 환경(jisu)에서만 사용자가 이 링크를 누르면 됨.
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
        out.fileHandleForReading.readabilityHandler = scan
        err.fileHandleForReading.readabilityHandler = scan

        // 종료까지 비동기 대기 (login 은 브라우저 인증까지 수십 초~수 분, 또는 cancelLogin 으로 즉시 종료)
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
                try? await Task.sleep(for: .seconds(180))
                if p.isRunning { p.terminate() }
                resumeOnce()
            }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        loginProcess = nil
        return await status().loggedIn
    }

    /// 진행 중인 login 취소 — 프로세스 종료 (사용자가 브라우저를 닫았거나 그만둘 때).
    static func cancelLogin() {
        loginProcess?.terminate()
        loginProcess = nil
    }

    /// `claude auth status` 실행 — stdout+stderr 합쳐 반환.
    private static func runStatus() async -> String {
        let p = Process()
        let claudePath = PingRunner.claudePath()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.arguments = ["auth", "status"]
        p.environment = claudeEnv(claudePath)
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

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
                try? await Task.sleep(for: .seconds(30))
                if p.isRunning { p.terminate() }
                resumeOnce()
            }
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        return (String(data: o, encoding: .utf8) ?? "") + (String(data: e, encoding: .utf8) ?? "")
    }

    /// 로그인 셸 env 흡수 + claudeDir PATH 보강 (RoutineService 와 동일 정책).
    private static func claudeEnv(_ claudePath: String) -> [String: String] {
        var env = RoutineService.loginShellEnv ?? ProcessInfo.processInfo.environment
        let claudeDir = (claudePath as NSString).deletingLastPathComponent
        let shellPath = env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = shellPath.contains(claudeDir) ? shellPath : "\(claudeDir):\(shellPath)"
        return env
    }
}
