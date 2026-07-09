import SwiftUI
import AppKit

/// 진단 항목 한 줄 — 신호등 레벨 + 상세 + (선택) 액션 버튼.
struct DoctorCheck: Identifiable {
    enum Level { case ok, warn, fail, loading }
    let id: String
    let title: String
    var level: Level
    var detail: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil
}

/// Pacer 가 의존하는 외부 상태(claude·토큰·루틴·사용량)를 점검해 신호등으로 보여준다.
/// 이번 팀 지원 사가(낡은 claude 바이너리·토큰 만료 등)를 사용자가 스스로 진단하도록 제품화.
@MainActor
final class DoctorModel: ObservableObject {
    @Published var checks: [DoctorCheck] = []
    @Published var running = false
    unowned let usage: UsageModel
    private var lang: String { UserDefaults.standard.string(forKey: "pacerLang") ?? "en" }

    init(usage: UsageModel) { self.usage = usage }

    /// 전체 점검 — 자리표시(로딩) 먼저 그린 뒤 각 체크를 동시 실행해 채운다.
    func runAll() async {
        running = true
        // claude 비의존 체크 즉시 + claude 의존 체크는 로딩 표시
        checks = [
            DoctorCheck(id: "claude", title: "Claude Code", level: .loading, detail: tr(lang, "Checking…", "확인 중…")),
            nodeCheck(),
            DoctorCheck(id: "login", title: tr(lang, "Sign-in", "로그인"), level: .loading, detail: tr(lang, "Checking…", "확인 중…")),
            usageCheck(),
            DoctorCheck(id: "sched", title: tr(lang, "Ping schedule", "핑 스케줄"), level: .loading, detail: tr(lang, "Checking…", "확인 중…")),
            DoctorCheck(id: "version", title: tr(lang, "Pacer version", "Pacer 버전"), level: .loading, detail: tr(lang, "Checking…", "확인 중…")),
        ]
        // claude 의존 + 버전 체크 동시 실행 + 끝나는 대로 즉시 갱신 — 느린 루틴(~20s)이 빠른 것들을 안 막게
        // (cwd 충돌은 routine 만 .skillrun 써서 무관)
        await withTaskGroup(of: DoctorCheck.self) { group in
            group.addTask { await self.claudeCheck() }
            group.addTask { await self.loginCheck() }
            group.addTask { await self.scheduleCheck() }
            group.addTask { await self.versionCheck() }
            for await check in group { update(check) }
        }
        running = false
    }

    private func update(_ check: DoctorCheck) {
        if let i = checks.firstIndex(where: { $0.id == check.id }) { checks[i] = check } else { checks.append(check) }
    }

    // MARK: 개별 체크

    /// Claude Code — 경로·버전, 다중 설치 경고(jisu 케이스), 미설치 시 설치 안내.
    private func claudeCheck() async -> DoctorCheck {
        let paths = ClaudeCLI.allClaudePaths()
        guard !paths.isEmpty else {
            return DoctorCheck(id: "claude", title: "Claude Code", level: .fail,
                detail: tr(lang, "Not found in PATH", "PATH 에서 claude 를 못 찾음"),
                actionLabel: tr(lang, "Install", "설치"),
                action: { NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!) })
        }
        let used = PingRunner.claudePath()
        let ver = await ClaudeCLI.version() ?? "?"
        var level: DoctorCheck.Level = .ok
        var detail = "\(used)  ·  v\(ver)"
        if paths.count > 1 {
            // 여러 claude 설치 — Pacer 는 첫 번째(PATH 우선)를 씀. 구버전 혼재 주의.
            level = .warn
            detail += "\n" + tr(lang, "Multiple installs found — using the one above:",
                                    "여러 개 설치됨 — 위의 것을 사용 (구버전 혼재 주의):") + "\n" + paths.joined(separator: "\n")
        }
        return DoctorCheck(id: "claude", title: "Claude Code", level: level, detail: detail)
    }

    /// 로그인 — claude auth status(이메일·플랜). 미로그인 시 로그인 버튼.
    private func loginCheck() async -> DoctorCheck {
        let s = await AuthService.status()
        if s.loggedIn {
            let info = [s.email, s.plan.map { "Plan: \($0.capitalized)" }].compactMap { $0 }.joined(separator: " · ")
            return DoctorCheck(id: "login", title: tr(lang, "Sign-in", "로그인"), level: .ok,
                detail: info.isEmpty ? tr(lang, "Signed in", "로그인됨") : info)
        }
        return DoctorCheck(id: "login", title: tr(lang, "Sign-in", "로그인"), level: .fail,
            detail: tr(lang, "Not signed in", "로그인 안 됨"),
            actionLabel: tr(lang, "Sign in", "로그인"), action: { [usage] in Task { await usage.login() } })
    }

    /// Node.js — 시스템에 node 가 있는지 넓게 탐색 (claude PATH + 흔한 위치 + nvm 버전 디렉터리).
    /// claude PATH 엔 없어도(-lc 라 .zshrc 의 nvm 미포함) 시스템엔 있을 수 있어 헷갈리지 않게 폭넓게 본다.
    /// node 는 Pacer 핵심 동작엔 불필요(루틴은 --setting-sources 격리, claude 는 standalone) — 그래서 없어도 선택.
    private func nodeCheck() -> DoctorCheck {
        let fm = FileManager.default
        var dirs = (ClaudeCLI.env(for: PingRunner.claudePath())["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        // nvm 버전 디렉터리 (최신 우선)
        let nvm = NSHomeDirectory() + "/.nvm/versions/node"
        if let vers = try? fm.contentsOfDirectory(atPath: nvm) {
            dirs += vers.sorted().reversed().map { "\(nvm)/\($0)/bin" }
        }
        for d in dirs where fm.isExecutableFile(atPath: d + "/node") {
            return DoctorCheck(id: "node", title: "Node.js", level: .ok, detail: d + "/node")
        }
        return DoctorCheck(id: "node", title: "Node.js", level: .warn,
            detail: tr(lang, "Not found (optional — some plugins/MCP need it)", "찾을 수 없음 (선택 — 일부 플러그인·MCP 용)"))
    }

    /// Pacer 버전 — 최신 릴리즈를 직접 확인(닥터 열 때마다). 새 버전 있으면 🟡 + 업데이트 버튼.
    private func versionCheck() async -> DoctorCheck {
        let ver = Updater.currentVersion()
        let latest = await Updater.latestVersion()
        if let latest, Updater.isNewer(latest, than: ver) {
            // 메인 화면에도 동기화 — 닥터는 아는데 팝오버 배너·아이콘 점은 24h 타이머를 기다리던 불일치 제거
            usage.availableUpdate = latest
            return DoctorCheck(id: "version", title: tr(lang, "Pacer version", "Pacer 버전"), level: .warn,
                detail: tr(lang, "\(ver) — update \(latest) available", "\(ver) — 새 버전 \(latest) 있음"),
                actionLabel: tr(lang, "Update", "업데이트"), action: { Updater.runUpdate(latest: latest) })
        }
        return DoctorCheck(id: "version", title: tr(lang, "Pacer version", "Pacer 버전"), level: .ok,
            detail: tr(lang, "\(ver) (latest)", "\(ver) (최신)"))
    }

    /// 사용량 API — UsageModel 상태 기반(claude 호출 없음).
    private func usageCheck() -> DoctorCheck {
        if usage.usage != nil {
            return DoctorCheck(id: "usage", title: tr(lang, "Usage API", "사용량 API"), level: .ok,
                detail: tr(lang, "Loaded", "정상 조회됨"))
        }
        return DoctorCheck(id: "usage", title: tr(lang, "Usage API", "사용량 API"),
            level: usage.error != nil ? .fail : .warn,
            detail: usage.error ?? tr(lang, "No data yet", "아직 데이터 없음"),
            actionLabel: tr(lang, "Refresh", "새로고침"), action: { [usage] in Task { await usage.refresh(force: true) } })
    }

    /// 핑 스케줄 — cloud: 루틴 등록·활성, local: launchd 설치 여부.
    private func scheduleCheck() async -> DoctorCheck {
        let mode = Config.load().mode
        if mode == "cloud" {
            let r = await RoutineService.run("status")
            let healthy = (r?.ok == true) && !((r?.id.isEmpty) ?? true) && (r?.enabled == true)
            if healthy {
                var detail = tr(lang, "Registered · enabled", "등록됨 · 활성")
                if let next = r?.nextRunAt {
                    let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm"; df.timeZone = TimeZone(identifier: "Asia/Seoul")
                    detail += " · " + tr(lang, "next ", "다음 ") + df.string(from: next) + " KST"
                }
                return DoctorCheck(id: "sched", title: tr(lang, "Cloud routine", "클라우드 루틴"), level: .ok, detail: detail)
            }
            return DoctorCheck(id: "sched", title: tr(lang, "Cloud routine", "클라우드 루틴"), level: .warn,
                detail: r?.reason == "no_env"
                    ? tr(lang, "No cloud environment", "클라우드 환경 없음")
                    : tr(lang, "Not registered / disabled — open Settings to apply", "미등록 또는 비활성 — 설정에서 적용"))
        }
        let installed = PingScheduler.isInstalled()
        return DoctorCheck(id: "sched", title: tr(lang, "Local pings (launchd)", "로컬 핑 (launchd)"),
            level: installed ? .ok : .warn,
            detail: installed ? tr(lang, "Installed", "설치됨") : tr(lang, "Not installed — open Settings to apply", "미설치 — 설정에서 적용"))
    }

    /// 모든 진단을 텍스트로 — 팀 지원 시 클립보드 복사용 (터미널 명령 대신 붙여넣기).
    func diagnosticsText() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        var lines = ["Pacer \(ver) · \(os)"]
        for c in checks {
            let m: String
            switch c.level { case .ok: m = "OK"; case .warn: m = "WARN"; case .fail: m = "FAIL"; case .loading: m = "…" }
            lines.append("[\(m)] \(c.title): \(c.detail.replacingOccurrences(of: "\n", with: " | "))")
        }
        lines.append("PATH: " + (ClaudeCLI.loginShellEnv?["PATH"] ?? "(shell env capture failed)"))
        return lines.joined(separator: "\n")
    }
}

struct DoctorView: View {
    @AppStorage("pacerLang") private var lang = "en"
    @StateObject private var model: DoctorModel

    init(model: DoctorModel) { _model = StateObject(wrappedValue: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope").foregroundStyle(Color.pacerPurple)
                Text(tr(lang, "Pacer Doctor", "Pacer 닥터")).font(.system(size: 16, weight: .bold))
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
                Button(action: { Task { await model.runAll() } }) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(model.running)
            }

            ForEach(model.checks) { check in row(check) }

            Divider()
            HStack(spacing: 10) {
                Button(tr(lang, "Copy diagnostics", "진단 복사")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.diagnosticsText(), forType: .string)
                }
                Button(tr(lang, "Open routine log", "루틴 로그 열기")) { openRoutineLog() }
                Spacer()
            }
            .font(.system(size: 11))
        }
        .padding(18)
        .frame(width: 460)
        .background(Color(red: 0.11, green: 0.11, blue: 0.125))
        .task { await model.runAll() }
    }

    private func row(_ c: DoctorCheck) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusDot(c.level).padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.system(size: 12.5, weight: .semibold))
                Text(c.detail).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let label = c.actionLabel, let action = c.action {
                Button(label, action: action).font(.system(size: 11))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
    }

    private func statusDot(_ level: DoctorCheck.Level) -> some View {
        Group {
            switch level {
            case .loading: ProgressView().controlSize(.small).scaleEffect(0.6)
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
        .font(.system(size: 13))
        .frame(width: 16, height: 16)
    }

    private func openRoutineLog() {
        let dir = NSHomeDirectory() + "/.config/claude-pacer"
        let log = dir + "/routine-debug.log"
        if FileManager.default.fileExists(atPath: log) {
            NSWorkspace.shared.selectFile(log, inFileViewerRootedAtPath: "")
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir)
        }
    }
}
