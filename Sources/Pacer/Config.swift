import Foundation

/// 사용자 설정 — ~/.config/claude-pacer/config.json.
struct Config: Codable, Equatable {
    var pingTimes: [String]   // "HH:mm"
    var skipWeekends: Bool
    var skipHolidays: Bool
    var pingMode: String? = nil   // "local"(launchd) | "cloud"(routine). nil → local
    var authPassed: Bool? = nil   // Pacer 통한 1회 로그인(claude auth login) 완료 여부. nil/false → 첫 실행 로그인 게이트
    var fablePing: Bool? = nil    // Fable 트래킹 — 핑을 Fable 모델로 발송(주간 창 정렬·인지) + 게이지 상시 표시. nil → off

    /// 현재 핑 방식 (nil 은 local 로 간주).
    var mode: String { pingMode ?? "local" }

    /// Fable 트래킹 여부 (nil 은 off).
    var fableOn: Bool { fablePing ?? false }

    static let defaults = Config(pingTimes: ["08:00", "13:00", "18:00"], skipWeekends: true, skipHolidays: true, pingMode: "local")

    static var dir: String { NSHomeDirectory() + "/.config/claude-pacer" }
    static var path: String { dir + "/config.json" }

    static func load() -> Config {
        guard
            let data = FileManager.default.contents(atPath: path),
            let cfg = try? JSONDecoder().decode(Config.self, from: data)
        else { return defaults }
        return cfg
    }

    func save() {
        try? FileManager.default.createDirectory(atPath: Config.dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: URL(fileURLWithPath: Config.path))
        }
    }
}
