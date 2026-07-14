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
        // -l(login, 비인터랙티브): .zshenv·.zprofile·.zlogin 만 소싱 — .zshrc(인터랙티브)는 제외.
        // 인터랙티브 도구(zoxide·플러그인 등)가 보호폴더 건드려 TCC 권한 팝업 뜨던 것 방지. 로그인 PATH 는 유지.
        // (claude 경로는 후보 탐색이, node 는 --setting-sources 격리가 커버 → .zshrc 안 봐도 무방)
        p.arguments = ["-lc", "/usr/bin/env -0"]
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

    /// `claude --version` → 버전 문자열(예: "2.1.191"). 실패 시 nil. (Doctor 진단용)
    static func version() async -> String? {
        let path = PingRunner.claudePath()
        let r = await run(executable: path, args: ["--version"], env: env(for: path), timeout: 15)
        guard let m = r.output.range(of: "[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression) else { return nil }
        return String(r.output[m])
    }

    /// 플래그 지원 캐시 — claudePath 별 `--help` 결과 (앱 실행 동안 유지. 재설치 시 앱 재시작이면 충분)
    private static var helpCache: [String: String] = [:]

    /// 현재 claude 가 특정 플래그를 지원하는지 — `--help` 출력에서 검색 (구버전 CLI 방어용).
    /// jisu 케이스: 1.0.65 는 --setting-sources 미지원 → 애매한 실패 대신 명확한 업데이트 안내를 위해 사전 감지.
    /// @param flag 예: "--setting-sources"
    /// @returns 지원 true / 미지원 false. --help 자체 실패(출력 없음)면 true(가드 통과 — 오탐으로 기능 차단 방지)
    static func supportsFlag(_ flag: String) async -> Bool {
        let path = PingRunner.claudePath()
        if helpCache[path] == nil {
            let r = await run(executable: path, args: ["--help"], env: env(for: path), timeout: 15)
            helpCache[path] = r.output
        }
        let help = helpCache[path] ?? ""
        guard !help.isEmpty else { return true }
        return help.contains(flag)
    }

    /// nvm 노드 버전 bin 의 claude 후보 (최신 버전 우선) — npm 글로벌 설치 케이스.
    /// nvm 초기화는 .zshrc(인터랙티브)에 있어 `-lc` 로그인 셸 PATH 에 안 잡힘 (bell 케이스 — Doctor node 탐지와 동일 원인).
    static func nvmClaudeCandidates() -> [String] {
        let base = NSHomeDirectory() + "/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        return versions
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { base + "/\($0)/bin/claude" }
    }

    /// PATH·알려진 위치에서 발견되는 모든 claude 경로 (which -a 격) — 다중 설치 감지용.
    /// 첫 항목이 실제로 Pacer 가 쓰는 것(PingRunner.claudePath 와 동일 순서).
    static func allClaudePaths() -> [String] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [String] = []
        let add: (String) -> Void = { c in
            guard fm.isExecutableFile(atPath: c), !seen.contains(c) else { return }
            seen.insert(c); result.append(c)
        }
        let shellPath = loginShellEnv?["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in shellPath.split(separator: ":") { add(String(dir) + "/claude") }
        // PATH 에 없을 수도 있는 알려진 위치 + nvm 노드 bin (npm 글로벌 설치)
        for c in [NSHomeDirectory() + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] { add(c) }
        for c in nvmClaudeCandidates() { add(c) }
        return result
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
        var launchFailed = false
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
            do { try p.run() } catch { launchFailed = true; resumeOnce(); return }
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

        // 실행 자체 실패(claude 미설치·경로 소실) — 미실행 프로세스의 terminationStatus 접근은 크래시라 즉시 반환
        if launchFailed {
            return Result(output: "launch-failed: \(executable) 를 실행할 수 없습니다 (Claude Code 미설치/경로 소실?)", status: -1, timedOut: false)
        }

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let combined = (String(data: outData, encoding: .utf8) ?? "")
            + (String(data: errData, encoding: .utf8) ?? "")
        return Result(output: combined, status: p.terminationStatus, timedOut: timedOut)
    }
}
