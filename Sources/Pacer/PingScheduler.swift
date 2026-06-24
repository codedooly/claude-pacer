import Foundation

/// launchd LaunchAgent 관리 — 핑 시각에 `Pacer --ping` 을 호출하도록 plist 생성/리로드.
enum PingScheduler {
    static let label = "com.dooly.pacer.ping"
    static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }

    /// 핑 plist 가 설치돼 있는지 (launchd 등록 여부 근사).
    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// config 의 핑 시각으로 plist 를 다시 쓰고 launchd 에 리로드.
    static func reinstall(_ cfg: Config) {
        guard let exe = Bundle.main.executablePath else { return }

        var intervals = ""
        for t in cfg.pingTimes {
            let parts = t.split(separator: ":")
            let h = Int(parts.first ?? "0") ?? 0
            let m = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
            intervals += "    <dict><key>Hour</key><integer>\(h)</integer><key>Minute</key><integer>\(m)</integer></dict>\n"
        }

        // launchd 는 최소 PATH 라 claude 를 찾도록 경로를 박는다
        let claudeDir = (PingRunner.claudePath() as NSString).deletingLastPathComponent

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array><string>\(exe)</string><string>--ping</string></array>
          <key>StartCalendarInterval</key>
          <array>
        \(intervals)  </array>
          <key>EnvironmentVariables</key>
          <dict><key>PATH</key><string>\(claudeDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
          <key>StandardErrorPath</key><string>\(Config.dir)/ping.err.log</string>
        </dict>
        </plist>
        """

        let agentsDir = NSHomeDirectory() + "/Library/LaunchAgents"
        try? FileManager.default.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)
        try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
        launchctl("unload")
        launchctl("load")
    }

    /// Cloud(Routine) 모드 전환 시 launchd 핑 제거 — Routine 과 중복 발사 방지.
    static func uninstall() {
        launchctl("unload")
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    private static func launchctl(_ cmd: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = [cmd, plistPath]
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
    }
}
