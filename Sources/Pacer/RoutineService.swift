import Foundation

/// 스킬 결과(PACE_RESULT) 파싱 모델.
struct PaceResult {
    let ok: Bool
    let id: String
    let enabled: Bool
    let nextRunAt: Date?
    let cron: String
    let reason: String?   // 실패 사유 (예: "no_env" — 클라우드 환경 없음). 없으면 nil
    var errorDetail: String?   // PACE_RESULT 없거나 reason 없는 실패 시: 합친 출력 마지막 ~600자
}

/// 클라우드 routine 관리 — Pacer 는 triggers API 를 직접 못 쓰므로(Cloudflare),
/// 번들 내장 지침(PaceScheduleSkill.md)을 명령형으로 감싸 `claude -p` 로 실행하고 PACE_RESULT 를 파싱한다.
/// (글로벌 ~/.claude/skills 설치 없이 자체 완결 — 슬래시커맨드 해석에 의존하던 비결정성 제거)
enum RoutineService {
    /// @param action register | disable | enable | status
    /// @param times  register 시 핑 시각 ["08:00", ...] (그 외 무시)
    /// @param env    (선택) 사용자가 `/schedule` 에서 복사한 env_id — 환경 자동탐지 실패(no_env) 대비
    /// @returns 파싱된 PaceResult (실패 시 nil)
    static func run(_ action: String, times: [String] = [], env: String = "") async -> PaceResult? {
        // 번들 스킬 지침을 명령형으로 감싸 직접 실행 (글로벌 설치·슬래시커맨드 의존 제거 — 결정적 동작)
        guard let skillURL = Bundle.main.url(forResource: "PaceScheduleSkill", withExtension: "md"),
              let raw = try? String(contentsOf: skillURL, encoding: .utf8) else { return nil }
        // YAML 프론트매터(--- ... ---) 제거
        var body = raw
        if body.hasPrefix("---"), let end = body.range(of: "\n---", range: body.index(body.startIndex, offsetBy: 3)..<body.endIndex) {
            body = String(body[end.upperBound...])
        }
        let timesArg = times.isEmpty ? "" : times.sorted().joined(separator: ",")
        let argLine = (["ARGUMENTS:", action, timesArg, env].filter { !$0.isEmpty }).joined(separator: " ")
        let prompt = """
        아래 [지침]을 지금 실제로 실행하라. 지침을 요약·복창하지 말 것. 명시된 도구(RemoteTrigger)를 실제 호출해 작업을 수행하고, 반드시 마지막 줄에 PACE_RESULT 한 줄을 출력하라.

        \(argLine)

        [지침]
        \(body)
        """

        let p = Process()
        p.executableURL = URL(fileURLWithPath: PingRunner.claudePath())
        // 현재 모델 ID 직접 지정 — CLI 의 sonnet/haiku 단축 alias 는 구버전이면 은퇴 스냅샷으로 풀려 404.
        // 전체 ID 를 주면 CLI 가 그대로 API 로 넘겨 서버가 해석한다.
        p.arguments = ["--model", "claude-sonnet-4-6", "-p", prompt]
        // 빈 전용 cwd — config.json 등 로컬 파일을 모델이 읽고 '이미 설정됨'으로 오판하는 것 방지 (+ TCC 팝업 방지)
        let workDir = NSHomeDirectory() + "/.config/claude-pacer/.skillrun"
        try? FileManager.default.removeItem(atPath: workDir)
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        p.currentDirectoryURL = URL(fileURLWithPath: workDir)
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
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

        // stdout + stderr 합쳐 읽기 — 실패 시 실제 에러(404 등)를 사용자에게 노출하기 위함
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let combined = (String(data: outData, encoding: .utf8) ?? "")
            + (String(data: errData, encoding: .utf8) ?? "")
        // 합친 출력의 마지막 ~600자 (PACE_RESULT 미발견·reason 없는 실패 시 errorDetail 로 전달)
        let rawTail = String(combined.suffix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
        return parse(combined, rawTail: rawTail)
    }

    /// 출력에서 PACE_RESULT 줄을 찾아 JSON 파싱. 못 찾거나 ok=false·reason 없으면 errorDetail 채움.
    private static func parse(_ output: String, rawTail: String) -> PaceResult? {
        for line in output.split(separator: "\n") where line.contains("PACE_RESULT") {
            let json = line
                .replacingOccurrences(of: "PACE_RESULT", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard
                let d = json.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { continue }
            let ok = obj["ok"] as? Bool ?? false
            let reason = obj["reason"] as? String
            return PaceResult(
                ok: ok,
                id: obj["id"] as? String ?? "",
                enabled: obj["enabled"] as? Bool ?? false,
                nextRunAt: (obj["next_run_at"] as? String).flatMap { UsageService.parseReset($0) },
                cron: obj["cron"] as? String ?? "",
                reason: reason,
                // ok=false 인데 reason 도 없으면 원인 추적용 원문 꼬리 전달
                errorDetail: (!ok && reason == nil) ? rawTail : nil
            )
        }
        // PACE_RESULT 자체를 못 찾음 → 실패. 원문 꼬리를 errorDetail 로 반환해 호출자가 메시지를 받게
        return PaceResult(ok: false, id: "", enabled: false, nextRunAt: nil, cron: "", reason: nil, errorDetail: rawTail)
    }
}
