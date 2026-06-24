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

    /// 5시간 창을 여는 최소 프롬프트.
    private static func fireClaude() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath())
        p.arguments = ["-p", "ok"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// claude CLI 의 흔한 설치 경로를 순서대로 탐색.
    static func claudePath() -> String {
        let candidates = [
            "/opt/homebrew/bin/claude",
            NSHomeDirectory() + "/.local/bin/claude",
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
