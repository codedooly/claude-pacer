import Foundation

/// 번들에 내장한 pace-schedule 스킬을 사용자의 ~/.claude/skills 에 설치한다.
/// Pacer 가 `claude -p "/pace-schedule"` 로 routine 을 관리하려면, 설치한 사용자의
/// Claude Code 환경에 이 스킬이 존재해야 한다. (개발자 본인 환경 외 배포 대응)
enum SkillInstaller {
    /// 번들 스킬을 ~/.claude/skills/pace-schedule/SKILL.md 로 복사 (내용이 다를 때만 갱신).
    static func installIfNeeded() {
        guard
            let src = Bundle.main.url(forResource: "PaceScheduleSkill", withExtension: "md"),
            let content = try? String(contentsOf: src, encoding: .utf8)
        else { return }

        let dir = NSHomeDirectory() + "/.claude/skills/pace-schedule"
        let dest = dir + "/SKILL.md"

        // 이미 같은 내용이면 건너뜀 (버전 갱신 시에만 덮어씀)
        if let existing = try? String(contentsOfFile: dest, encoding: .utf8), existing == content { return }

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? content.write(toFile: dest, atomically: true, encoding: .utf8)
    }
}
