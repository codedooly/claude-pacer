import Foundation

/// `Pacer --ping [HH:mm]` 모드 — launchd 가 호출. 핑 발사 + 로그 후 종료.
enum PingRunner {
    static func run() {
        let cfg = Config.load()

        // 주말 skip
        let wd = Calendar.current.component(.weekday, from: Date())
        if cfg.skipWeekends && (wd == 1 || wd == 7) { return }
        // 공휴일 skip (한국 공휴일 — Foundation 음력 계산)
        if cfg.skipHolidays && KoreanHolidays.isHoliday(Date()) { return }

        let slot = slotArg() ?? nowHM()
        let ok = fireClaude()
        log(slot: slot, status: ok ? "sent" : "failed")
        if !ok { notify("Ping failed at \(slot) — check Claude login / network") }
    }

    /// `--ping 08:00` 처럼 슬롯이 넘어오면 사용, 없으면 현재 시각.
    private static func slotArg() -> String? {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--ping"), i + 1 < args.count, args[i + 1].contains(":") {
            return args[i + 1]
        }
        return nil
    }

    private static func nowHM() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: Date())
    }

    /// 5시간 창을 여는 최소 프롬프트. launchd 핑은 격리 실행 — 인터랙티브 셸 소싱·홈 스캔을 피해
    /// 사진·음악 등 보호폴더 TCC 권한 팝업이 뜨지 않게 한다.
    private static func fireClaude() -> Bool {
        // Fable 트래킹 ON + Fable 주간 창이 닫혀 있을 때만 Fable 로 발사(새 창 즉시 오픈 — 리셋 시점 정렬).
        // 창이 이미 활성이면 Fable 로 쏴도 이득이 없으므로(창 연장 X) 저렴 모델로. 실패(모델 미제공 등) 시 기본 모델 폴백
        if Config.load().fableOn, fableWindowClosed(), fireClaude(model: "claude-fable-5") { return true }
        return fireClaude(model: "claude-haiku-4-5-20251001")
    }

    /// Fable 주간 창이 닫혀 있는가 — usage API 의 weekly_scoped: resets_at 이 없거나(미사용) 과거(만료)면 true.
    /// 판단 불가(토큰·네트워크 실패)면 true — Fable 로 쏘는 쪽이 안전 (활성 중 중복 발사는 무해, 폴백도 있음).
    private static func fableWindowClosed() -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var closed = true
        Task {
            defer { sem.signal() }
            guard case .success(let u) = await UsageService().fetch() else { return }
            // scoped(Fable 등)가 하나라도 활성(미래 resets_at)이면 창 열려 있음
            closed = !u.weeklyScoped.contains { ($0.resetsAt?.timeIntervalSinceNow ?? -1) > 0 }
        }
        _ = sem.wait(timeout: .now() + 15)
        return closed
    }

    private static func fireClaude(model: String) -> Bool {
        let bin = pingClaudePath()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        // 현재 모델 ID 직접 지정 — 단축 alias 는 구버전 CLI 에서 은퇴 스냅샷으로 풀려 404. 기본 핑은 저렴 모델로 충분
        p.arguments = ["--model", model, "-p", "ok"]
        // 빈 전용 cwd — claude 가 홈/보호폴더(사진·음악·문서)를 스캔해 권한 팝업 뜨는 것 방지
        let workDir = NSHomeDirectory() + "/.config/claude-pacer/.skillrun"
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        p.currentDirectoryURL = URL(fileURLWithPath: workDir)
        // 깨끗한 PATH — 인터랙티브 셸(.zshrc) 소싱 없이. launchd 핑에서 셸 도구가 보호폴더 건드리는 것 방지
        var env = ProcessInfo.processInfo.environment
        let claudeDir = (bin as NSString).deletingLastPathComponent
        env["PATH"] = "\(claudeDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// 핑 전용 claude 탐색 — 알려진 위치만 (인터랙티브 셸 소싱 X → launchd 권한 팝업 방지).
    /// .local/bin 우선(standalone 최신본). 핑은 `claude -p ok` 뿐이라 구버전이어도 동작.
    private static func pingClaudePath() -> String {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return "/opt/homebrew/bin/claude"
    }

    /// 터미널이 쓰는 바로 그 claude 를 선택 — 로그인 셸 PATH 를 순서대로 탐색.
    /// (구/신버전이 혼재할 때 PATH 우선순위 = 터미널과 동일 → 신버전 standalone 선택, 구버전 homebrew 회피)
    static func claudePath() -> String {
        // 로그인 셸 PATH 순서대로 탐색 (없으면 현재 프로세스 env PATH)
        let shellPath = ClaudeCLI.loginShellEnv?["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in shellPath.split(separator: ":") {
            let c = String(dir) + "/claude"
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        // 폴백 — 알려진 위치 (.local/bin 우선: standalone 최신본이 보통 여기)
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return "/opt/homebrew/bin/claude"
    }

    private static func log(slot: String, status: String) {
        try? FileManager.default.createDirectory(atPath: Config.dir, withIntermediateDirectories: true)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "{\"date\":\"\(today)\",\"slot\":\"\(slot)\",\"status\":\"\(status)\",\"ts\":\"\(ts)\"}\n"
        let path = Config.dir + "/pings.jsonl"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            if let d = line.data(using: .utf8) { h.write(d) }
            h.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func notify(_ msg: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(msg)\" with title \"Pacer\""]
        try? p.run()
    }
}
