import Foundation

/// 스킬 결과(PACE_RESULT) 파싱 모델.
struct PaceResult {
    let ok: Bool
    let id: String
    let enabled: Bool
    let nextRunAt: Date?
    let cron: String
}

/// 클라우드 routine 관리 — Pacer 는 triggers API 를 직접 못 쓰므로(Cloudflare),
/// `claude -p "/pace-schedule <action> [times]"` 로 CLI 를 다리 삼아 호출하고 PACE_RESULT 를 파싱한다.
enum RoutineService {
    /// @param action register | disable | enable | status
    /// @param times  register 시 핑 시각 ["08:00", ...] (그 외 무시)
    /// @returns 파싱된 PaceResult (실패 시 nil)
    static func run(_ action: String, times: [String] = []) async -> PaceResult? {
        let arg = times.isEmpty
            ? "/pace-schedule \(action)"
            : "/pace-schedule \(action) \(times.sorted().joined(separator: ","))"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: PingRunner.claudePath())
        p.arguments = ["-p", arg]
        // 격리 cwd — claude 가 다운로드/데스크탑/음악 등 일반 폴더를 훑지 않게 (Pacer TCC 권한 팝업 방지)
        let workDir = NSHomeDirectory() + "/.config/claude-pacer"
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        p.currentDirectoryURL = URL(fileURLWithPath: workDir)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        // claude 가 하위 도구를 찾도록 PATH 보강
        var env = ProcessInfo.processInfo.environment
        let claudeDir = (PingRunner.claudePath() as NSString).deletingLastPathComponent
        env["PATH"] = "\(claudeDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env

        // 종료까지 비동기 대기 (claude 세션이 수 초~분 걸림)
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

            // terminationHandler 를 run() 이전에 설정 — 즉시 종료를 놓치지 않게
            p.terminationHandler = { _ in resumeOnce() }

            do { try p.run() } catch { resumeOnce(); return }

            // 타임아웃 60초 — 네트워크·claude 문제로 무한 대기 방지
            Task {
                try? await Task.sleep(for: .seconds(60))
                if p.isRunning { p.terminate() }
                // terminate 후에도 핸들러가 안 불릴 수 있으니 직접 가드 거쳐 resume
                resumeOnce()
            }
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        return parse(s)
    }

    /// 출력에서 PACE_RESULT 줄을 찾아 JSON 파싱.
    private static func parse(_ output: String) -> PaceResult? {
        for line in output.split(separator: "\n") where line.contains("PACE_RESULT") {
            let json = line
                .replacingOccurrences(of: "PACE_RESULT", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard
                let d = json.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { continue }
            return PaceResult(
                ok: obj["ok"] as? Bool ?? false,
                id: obj["id"] as? String ?? "",
                enabled: obj["enabled"] as? Bool ?? false,
                nextRunAt: (obj["next_run_at"] as? String).flatMap { UsageService.parseReset($0) },
                cron: obj["cron"] as? String ?? ""
            )
        }
        return nil
    }
}
