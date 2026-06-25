import Foundation

/// claude CLI 호출 공통 — 로그인 셸 env 흡수, claude 바이너리 env 보강, 프로세스 실행(타임아웃·더블resume 가드).
/// RoutineService·AuthService 가 공유한다 (예전엔 각자 복붙).
enum ClaudeCLI {
    /// 로그인 셸 env 캐시 — GUI(.app)의 launchd 최소 env 를 터미널과 동일하게 보강 (1회 캡처 후 재사용).
    static let loginShellEnv: [String: String]? = captureLoginShellEnv()

    /// `$SHELL -ilc 'env -0'` 로 로그인+인터랙티브 셸 env(.zprofile·.zshrc 의 nvm·PATH 포함)를 캡처.
    /// @returns env 딕셔너리 (실패·타임아웃 시 nil → 호출부가 ProcessInfo env 로 폴백)
    private static func captureLoginShellEnv() -> [String: String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        // -i(interactive)+l(login): .zprofile + .zshrc 까지 소싱해야 nvm 등 PATH 확보. env -0: NUL 구분(값에 개행 안전)
        p.arguments = ["-ilc", "/usr/bin/env -0"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()

        // 인터랙티브 셸 행(p10k 등) 방지 — 세마포어 5초 타임아웃
        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }
        do { try p.run() } catch { return nil }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            if p.isRunning { p.terminate() }
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        // NUL 구분 KEY=VALUE 파싱
        var dict: [String: String] = [:]
        for pair in str.split(separator: "\0") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            dict[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        return dict.isEmpty ? nil : dict
    }

    /// claude 실행용 env — 로그인 셸 env 흡수 + claudeDir 를 PATH 앞에 보장.
    /// @param claudePath 실행할 claude 절대경로
    static func env(for claudePath: String) -> [String: String] {
        var env = loginShellEnv ?? ProcessInfo.processInfo.environment
        let claudeDir = (claudePath as NSString).deletingLastPathComponent
        // claudeDir 를 PATH 앞에 보장 (셸 PATH 에 이미 있으면 그대로)
        let shellPath = env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = shellPath.contains(claudeDir) ? shellPath : "\(claudeDir):\(shellPath)"
        return env
    }

    /// 프로세스 실행 결과 — 합친 출력 + 종료 상태 + 타임아웃 여부.
    struct Result {
        let output: String     // stdout + stderr (onChunk 사용 시엔 핸들러 해제 후 잔여분만)
        let status: Int32
        let timedOut: Bool
    }

    /// 프로세스 실행 → 종료/타임아웃까지 대기. stdout+stderr 합쳐 반환.
    /// @param onStart  실행 직후 Process 핸들 전달 (취소용 — login 이 cancelLogin 에서 terminate)
    /// @param onChunk  stdout/stderr 증분 콜백 (login OAuth URL 스캔 등). nil 이면 종료 후 일괄 읽기
    /// @param timeout  초 단위 강제 종료 한도
    static func run(executable: String, args: [String], env: [String: String],
                    cwd: URL? = nil, timeout: TimeInterval,
                    onStart: ((Process) -> Void)? = nil,
                    onChunk: ((FileHandle) -> Void)? = nil) async -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = env
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        if let onChunk {
            out.fileHandleForReading.readabilityHandler = onChunk
            err.fileHandleForReading.readabilityHandler = onChunk
        }

        var timedOut = false
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            // continuation 더블 resume 방지 가드 (terminationHandler vs timeout 경쟁)
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
            onStart?(p)
            // 타임아웃 — 네트워크·claude 문제로 무한 대기 방지
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if p.isRunning { timedOut = true; p.terminate() }
                resumeOnce()
            }
        }
        if onChunk != nil {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let combined = (String(data: outData, encoding: .utf8) ?? "")
            + (String(data: errData, encoding: .utf8) ?? "")
        return Result(output: combined, status: p.terminationStatus, timedOut: timedOut)
    }
}
