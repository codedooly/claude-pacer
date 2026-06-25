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

        // claude -p 실행 → stdout+stderr 합친 출력 획득 (run()/fetchEnvId() 공유 보일러플레이트)
        let combined = await runClaude(prompt: prompt, label: "run \(argLine)")
        // 합친 출력의 마지막 ~600자 (PACE_RESULT 미발견·reason 없는 실패 시 errorDetail 로 전달)
        let rawTail = String(combined.suffix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
        return parse(combined, rawTail: rawTail)
    }

    /// 클라우드 환경 자동취득 — 신규 계정(trigger 0개)은 register 가 no_env 를 낸다.
    /// `/schedule` 로 "Available environments" 만 조회해 env_id 를 추출(생성·변경·실행 금지).
    /// @returns 첫 env_id (없으면 nil)
    static func fetchEnvId() async -> String? {
        let prompt = "/schedule 로 Available environments 만 조회. routine 생성·변경·실행 금지. 마지막 줄에 정확히 ENV_ID=<env_xxx 또는 NONE> 만 출력."

        // run() 과 동일 방식으로 실행 (같은 셋업·timeout·가드 재사용)
        let combined = await runClaude(prompt: prompt, label: "fetchEnvId")

        // ENV_ID=NONE 명시면 환경 없음
        if combined.contains("ENV_ID=NONE") { return nil }
        // 출력에서 첫 env_id 추출
        guard let range = combined.range(of: "env_[A-Za-z0-9]+", options: .regularExpression) else { return nil }
        return String(combined[range])
    }

    /// claude -p 실행 공통 보일러플레이트 — 모델·cwd·PATH·60초 timeout·더블 resume 가드.
    /// @param prompt 전달할 프롬프트
    /// @param label  진단 로그용 호출 식별자 (예: "run register ...", "fetchEnvId")
    /// @returns stdout + stderr 합친 출력
    private static func runClaude(prompt: String, label: String) async -> String {
        let p = Process()
        let claudePath = PingRunner.claudePath()
        p.executableURL = URL(fileURLWithPath: claudePath)
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
        let claudeDir = (claudePath as NSString).deletingLastPathComponent
        let pathValue = "\(claudeDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = pathValue
        p.environment = env

        let started = Date()
        var timedOut = false   // 타임아웃으로 강제 종료됐는지 (진단 로그용)

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
                if p.isRunning { timedOut = true; p.terminate() }
                // terminate 후에도 핸들러가 안 불릴 수 있으니 직접 가드 거쳐 resume
                resumeOnce()
            }
        }

        // stdout + stderr 합쳐 읽기 — 실패 시 실제 에러(404 등)를 사용자에게 노출하기 위함
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let combined = (String(data: outData, encoding: .utf8) ?? "")
            + (String(data: errData, encoding: .utf8) ?? "")

        // 진단 로그 적재 — GUI(.app) 실행 컨텍스트의 실제 입출력·환경 추적
        appendDebugLog(label: label, claudePath: claudePath, pathValue: pathValue,
                       env: env, started: started, exitStatus: p.terminationStatus,
                       timedOut: timedOut, output: combined)
        return combined
    }

    /// 루틴 실행 진단 로그 — Pacer 의 `claude -p` 호출 입출력·환경을 파일로 남긴다.
    /// GUI(.app)는 launchd 최소 env 로 실행돼 터미널과 달라질 수 있어, 그 차이를 추적하기 위함.
    /// 저장 위치: `~/.config/claude-pacer/routine-debug.log` (메뉴 "루틴 로그 열기"로 노출).
    private static func appendDebugLog(label: String, claudePath: String, pathValue: String,
                                       env: [String: String], started: Date, exitStatus: Int32,
                                       timedOut: Bool, output: String) {
        let dir = NSHomeDirectory() + "/.config/claude-pacer"
        let path = dir + "/routine-debug.log"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // PATH 안에서 node 실행파일 탐색 — (b) 환경 문제(노드 미발견)를 직접 판별
        var nodeFound = "NOT FOUND"
        for d in pathValue.split(separator: ":") {
            let cand = String(d) + "/node"
            if fm.isExecutableFile(atPath: cand) { nodeFound = cand; break }
        }
        // env 의 값은 토큰 등 민감정보일 수 있으므로 키 목록만 — 누락된 셸 변수(NVM 등) 식별용
        let envKeys = env.keys.sorted().joined(separator: ",")
        let stamp = ISO8601DateFormatter().string(from: started)
        let durMs = Int(Date().timeIntervalSince(started) * 1000)
        // 출력이 길면 꼬리 8000자만 (PACE_RESULT·RemoteTrigger 결과는 끝부분에 위치)
        let cappedOut = output.count > 8000 ? "…(앞부분 생략)\n" + String(output.suffix(8000)) : output
        let entry = """
        ════════ \(stamp) ════════
        label   : \(label)
        claude  : \(claudePath)
        PATH    : \(pathValue)
        node    : \(nodeFound)
        env-keys: \(envKeys)
        exit    : status=\(exitStatus) timedOut=\(timedOut) durationMs=\(durMs)
        ───── OUTPUT (stdout+stderr) ─────
        \(cappedOut)
        ═══════════════════════════════════════════

        """

        // 무한 증가 방지 — 256KB 초과 시 파일 새로 시작
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64, size > 256_000 {
            try? fm.removeItem(atPath: path)
        }
        guard let data = entry.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        } else {
            fm.createFile(atPath: path, contents: data)
        }
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
