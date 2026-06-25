import AppKit
import Combine
import SwiftUI

/// Pacer — Claude 5h/7d usage + window-alignment in your menu bar.
@main
struct PacerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 실제 설정 창은 AppDelegate 가 NSWindow 로 직접 관리 (LSUIElement 앱에서 SwiftUI Settings scene 이 안 열려서)
        Settings { EmptyView() }
    }
}

/// 메뉴바는 NSStatusItem 으로 직접 — 아이콘 + % 를 함께 표시 (MenuBarExtra 는 둘 중 하나만 됨).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = UsageModel()
    private var cancellable: AnyCancellable?
    private var pingLogWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // launchd 가 `Pacer --ping` 으로 부르면 핑만 쏘고 종료
        if CommandLine.arguments.contains("--ping") {
            PingRunner.run()
            NSApp.terminate(nil)
            return
        }
        // config 정규화 + 핑 스케줄 최신화
        let cfg = Config.load()
        cfg.save()
        // Cloud(Routine) 모드면 launchd 를 끄고(중복 핑 방지), Local 이면 스케줄 설치
        if cfg.mode == "cloud" {
            PingScheduler.uninstall()
        } else {
            PingScheduler.reinstall(cfg)
        }

        // 드롭다운(팝오버) — SwiftUI 카드
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)   // 다크 고정 (반투명 비침 방지 + 다크 디자인 유지)
        let host = NSHostingController(rootView: MenuContent(model: model, onPingLog: { [weak self] in self?.openPingLog() }, onSettings: { [weak self] in self?.openSettings() }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        // 메뉴바 아이템: 아이콘(template) + 5h%
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            let icon = NSImage(named: "MenuBarIcon")
            icon?.isTemplate = true
            btn.image = icon
            btn.imagePosition = .imageLeading
            btn.action = #selector(statusClick)
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])   // 좌클릭=팝오버, 우클릭=메뉴
        }
        updateTitle()
        cancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle() }
        }
    }

    private func updateTitle() {
        let text = model.usage?.fiveHour.map { " \($0.pct)%" } ?? ""
        statusItem.button?.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 12)] // 메뉴바 기본보다 작게
        )
    }

    /// 좌클릭 → 팝오버, 우클릭 → 메뉴(Refresh/Settings/Quit).
    @objc private func statusClick() {
        if NSApp.currentEvent?.type == .rightMouseUp { showStatusMenu() }
        else { togglePopover() }
    }

    private func showStatusMenu() {
        let lang = UserDefaults.standard.string(forKey: "pacerLang") ?? "en"
        let menu = NSMenu()
        menu.autoenablesItems = false
        let refresh = menu.addItem(withTitle: tr(lang, "Refresh", "새로고침"), action: #selector(menuRefresh), keyEquivalent: "")
        let settings = menu.addItem(withTitle: tr(lang, "Settings…", "설정…"), action: #selector(menuSettings), keyEquivalent: "")
        // 로그인 게이트 통과 전엔 새로고침·설정 비활성
        refresh.isEnabled = !model.loginGate
        settings.isEnabled = !model.loginGate
        menu.addItem(.separator())
        // Update·Help 는 로그인 여부와 무관하게 항상 활성
        menu.addItem(withTitle: tr(lang, "Update…", "업데이트…"), action: #selector(menuUpdate), keyEquivalent: "")
        menu.addItem(withTitle: tr(lang, "Re-login", "재로그인"), action: #selector(menuRelogin), keyEquivalent: "")
        menu.addItem(withTitle: tr(lang, "Help", "도움말"), action: #selector(menuHelp), keyEquivalent: "")
        // Cloud 루틴 진단 로그를 Finder 에서 노출 (지원·디버깅용)
        menu.addItem(withTitle: tr(lang, "Open Routine Log", "루틴 로그 열기"), action: #selector(openRoutineLog), keyEquivalent: "")
        #if PACER_DEBUG
        // 디버그 전용 — 팝업 체크 전용 창을 띄워 디자인·언어 토글 확인 (릴리즈 빌드엔 미포함)
        menu.addItem(.separator())
        let dbgItem = menu.addItem(withTitle: "🧪 팝업 체크", action: #selector(openDebugPopups), keyEquivalent: "")
        dbgItem.target = self
        #endif
        menu.addItem(.separator())
        menu.addItem(withTitle: tr(lang, "Quit Pacer", "Pacer 종료"), action: #selector(menuQuit), keyEquivalent: "")
        for item in menu.items { item.target = self }
        if let btn = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: btn.bounds.height + 4), in: btn)
        }
    }

    @objc private func menuRefresh() { Task { await model.refresh(force: true) } }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuUpdate() {
        // 최신 확인 거침 — 같으면 "최신입니다", 새 버전이면 현재→최신 화살표 확인 (About 과 동일 흐름)
        checkForUpdates()
    }
    @objc private func menuRelogin() {
        // 브라우저 OAuth 재로그인 (토큰 갱신) — 상태 무관 상시 제공
        Task { await model.login() }
    }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    /// 루틴 진단 로그를 Finder 에서 선택 노출 — 없으면 폴더만 연다.
    @objc private func openRoutineLog() {
        let dir = NSHomeDirectory() + "/.config/claude-pacer"
        let log = dir + "/routine-debug.log"
        if FileManager.default.fileExists(atPath: log) {
            NSWorkspace.shared.selectFile(log, inFileViewerRootedAtPath: "")
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir)
        }
    }

    #if PACER_DEBUG
    // 디버그 전용 — 팝업 체크 전용 창 (언어 토글 + 더미 다이얼로그, 릴리즈 빌드엔 미포함)
    private var debugWindow: NSWindow?

    /// 팝업 체크 창 — 다크 톤 작은 NSWindow 에 DebugPopupView 호스팅 (openPingLog 패턴).
    @objc func openDebugPopups() {
        if debugWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            w.title = "팝업 체크"
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentViewController = NSHostingController(
                rootView: DebugPopupView(onAbout: { [weak self] in self?.menuHelp() })
            )
            w.center()
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.moveToActiveSpace]
            debugWindow = w
        }
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        debugWindow?.makeKeyAndOrderFront(nil)
    }
    #endif

    /// 현재 앱 버전 (CFBundleShortVersionString).
    private func appVersion() -> String {
        Updater.currentVersion()
    }

    /// Help → 커스텀 About 창 (버전·라이선스 + 업데이트 확인 / GitHub / 닫기).
    @objc private func menuHelp() {
        let lang = UserDefaults.standard.string(forKey: "pacerLang") ?? "en"
        let version = appVersion()
        // 다크 톤 비-resizable 작은 창에 SwiftUI About 뷰 호스팅
        if aboutWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            w.title = "Pacer"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.isMovableByWindowBackground = true
            let about = AboutView(
                onCheckUpdate: { [weak self] in self?.checkForUpdates() },
                onGitHub: { NSWorkspace.shared.open(URL(string: "https://github.com/codedooly/claude-pacer")!) },
                onClose: { [weak self] in self?.aboutWindow?.performClose(nil) },
                lang: lang,
                version: version
            )
            let host = NSHostingController(rootView: about)
            host.sizingOptions = [.preferredContentSize]
            w.contentViewController = host
            w.center()
            aboutWindow = w
        }
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    /// GitHub 최신 릴리즈 태그를 받아 현재 버전과 semver 비교 → 업데이트 안내.
    private func checkForUpdates() {
        let lang = UserDefaults.standard.string(forKey: "pacerLang") ?? "en"
        let current = appVersion()
        // 최신 버전 fetch (공용 헬퍼) → 결과 표시
        Updater.fetchLatest { [weak self] latest in
            guard let self else { return }
            self.presentUpdateResult(latest: latest, current: current, lang: lang)
        }
    }

    /// checkForUpdates 결과를 Pacer 다이얼로그로 표시 (메인스레드).
    @MainActor private func presentUpdateResult(latest: String?, current: String, lang: String) {
        // 네트워크/파싱 실패
        guard let latest, !latest.isEmpty else {
            PacerDialog.show(title: "Pacer",
                message: tr(lang,
                    "Couldn't check for updates — check your connection.",
                    "업데이트 확인 실패 — 인터넷 연결을 확인하세요."),
                buttons: [("OK", true)])
            return
        }
        // semver 비교 (major.minor.patch 숫자)
        if Self.isNewer(latest, than: current) {
            // 새 버전 → 화살표 확인 팝업 하나만 (이중 팝업 금지)
            Updater.runUpdate(latest: latest)
        } else {
            PacerDialog.show(title: "Pacer",
                message: tr(lang,
                    "You're on the latest version (\(current)).",
                    "최신 버전입니다 (\(current))."),
                buttons: [(tr(lang, "OK", "확인"), true)])
        }
    }

    /// semver 숫자 비교 — a 가 b 보다 높으면 true.
    private static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 설정 창 — NSWindow 직접 관리 (메뉴 카드 버튼·우클릭 메뉴 공용).
    func openSettings() {
        let lang = UserDefaults.standard.string(forKey: "pacerLang") ?? "en"
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.moveToActiveSpace]   // 현재 보는 데스크탑(Space)으로 창이 따라옴
            settingsWindow = w
        }
        // 매 오픈마다 최신 config 로 SettingsView 새로 구성 — 재사용 창이라 init/onAppear 가 stale 되던 문제 방지
        // (cloud 인데 Local 탭 눌렀다 적용 안 하고 X 로 닫으면, 그 뷰의 mode 상태가 남아 다음에 Local 로 잘못 떠 보이던 버그)
        settingsWindow?.title = tr(lang, "Pacer Settings", "Pacer 설정")
        let host = NSHostingController(rootView: SettingsView())
        host.sizingOptions = [.preferredContentSize]
        settingsWindow?.contentViewController = host
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 매번 현재 화면의 메뉴바 아이콘 아래로 재배치 — 옛 위치/다른 데스크탑 모서리 잔류 방지 (autosave 미사용)
        if let w = settingsWindow { positionUnderStatusItem(w) }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// 설정 창 우측 상단을 메뉴바 아이콘 바로 아래에 맞춘다 (화면 밖이면 clamp).
    private func positionUnderStatusItem(_ w: NSWindow) {
        w.contentView?.layoutSubtreeIfNeeded()   // 콘텐츠 크기 확정 후 좌표 계산 (첫 오픈 시 크기 어긋남 방지)
        // 메뉴바 버튼의 스크린 좌표
        guard let buttonFrame = statusItem.button?.window?.frame else {
            w.center()
            return
        }
        let size = w.frame.size
        var origin = NSPoint(
            x: buttonFrame.maxX - size.width,        // 우측 상단이 버튼 아래
            y: buttonFrame.minY - size.height - 6
        )
        // 화면(아이콘이 있는 스크린) 안으로 clamp
        if let vis = (statusItem.button?.window?.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, vis.minX), vis.maxX - size.width)
            origin.y = min(max(origin.y, vis.minY), vis.maxY - size.height)
        }
        w.setFrameOrigin(origin)
    }

    @objc private func togglePopover() {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            Task { await model.refresh() }
        }
    }

    /// 핑 발사 상세 로그 창 (Table).
    private func openPingLog() {
        if pingLogWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false
            )
            w.title = "Pacer — Pace Log"
            w.contentViewController = NSHostingController(rootView: PingLogView())
            w.center()
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.moveToActiveSpace]   // 현재 보는 데스크탑으로 창이 따라옴 (Space 점프 방지)
            pingLogWindow = w
        }
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        pingLogWindow?.makeKeyAndOrderFront(nil)
    }
}

/// 메뉴 표시용 상태 + 갱신 로직.
@MainActor
final class UsageModel: ObservableObject {
    @Published var usage: Usage?
    @Published var plan: String?
    @Published var error: String?
    @Published var updatedAt: Date?
    @Published var pings: [String: String] = [:]
    @Published var usageHistory: [String: [String: Int]] = [:]

    @Published var pingTimes: [String] = Config.load().pingTimes
    @Published var pingMode: String = Config.load().mode
    @Published var holidays: Set<Date> = []
    @Published var authed: Bool = true
    @Published var authPassed: Bool = (Config.load().authPassed ?? false)   // Pacer 통한 1회 로그인 완료 여부
    @Published var loggingIn = false                                        // claude auth login 진행 중 (스피너)
    @Published var loginURL: URL?                                           // claude 가 출력한 OAuth URL (자동 안 열릴 때 클릭용)

    // 로그인 게이트 — Pacer 1회 로그인을 안 했거나(authPassed) 토큰이 없으면(authed) 로그인 화면을 강제
    var loginGate: Bool { !authPassed || !authed }

    // 에러 있고 usage 가 한 번도 안 들어옴 = 첫 설치/인증 실패 (일시적 갱신 실패와 구분)
    var needsConnectionHelp: Bool { error != nil && usage == nil }

    /// claude auth login(브라우저 OAuth) 실행 → 성공 시 authPassed 기록 + 즉시 새로고침.
    private var loginCancelled = false   // 사용자가 로그인을 취소했는지 (취소면 기존 토큰 있어도 통과 X)

    func login() async {
        loggingIn = true
        loginURL = nil
        loginCancelled = false
        // claude 가 브라우저 로그인 페이지를 띄우고 콜백까지 처리 (자동 안 열리면 onURL 로 받은 링크를 UI 에 노출)
        let ok = await AuthService.login(onURL: { [weak self] url in
            Task { @MainActor in self?.loginURL = url }
        })
        loggingIn = false
        loginURL = nil

        // 취소면 통과 X — 기존 토큰이 있어 status 가 loggedIn 이어도 게이트 유지 (사용자가 명시적으로 그만둠)
        if loginCancelled { loginCancelled = false; return }
        // 성공 시에만 게이트 통과 기록 (실패면 로그인 화면 유지)
        if ok {
            var c = Config.load(); c.authPassed = true; c.save()
            authPassed = true
            await refresh(force: true)
        }
    }

    /// 로그인 취소 — 진행 중 프로세스 종료, 스피너 해제 (다시 시도 가능 상태로).
    func cancelLogin() {
        loginCancelled = true
        AuthService.cancelLogin()
        loggingIn = false
        loginURL = nil
    }

    private let service = UsageService()
    private var lastFetch: Date?
    private var pollTimer: Timer?

    init() {
        authed = service.hasCredentials()
        Task { await refresh() }
        // Cloud 모드면 routine 실제 상태를 백그라운드 확인 (메인 칩 파랑/회색)
        if Config.load().mode == "cloud" {
            Task {
                let r = await RoutineService.run("status")
                let healthy = (r?.ok == true) && !((r?.id.isEmpty) ?? true) && (r?.enabled == true)
                UserDefaults.standard.set(healthy, forKey: "routineHealthy")
            }
        }
        // 자동 폴링 15분 — 너무 잦으면 429 나므로 넓게 (claude-usage-bar 는 30분)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh(force: Bool = false) async {
        // Keychain(security 서브프로세스)을 refresh 당 1회만 읽어 authed·plan·fetch 로 전달
        let oauth = service.oauthDict()
        authed = service.hasCredentials(from: oauth)   // 토큰 생기면 온보딩 → 메인 전환
        // config(모드·핑·공휴일·로그)는 쿨다운과 무관하게 매번 즉시 반영 — 설정 변경이 바로 보이게
        let cfg = Config.load()
        pingTimes = cfg.pingTimes
        pingMode = cfg.mode
        holidays = cfg.skipHolidays ? KoreanHolidays.holidays(year: Calendar.current.component(.year, from: Date())) : []
        pings = PingLog.load()
        plan = service.plan(from: oauth)
        usageHistory = UsageHistory.load()

        // usage API 만 쿨다운(429 회피): Refresh 버튼 5초, 자동/팝업 60초 내 재호출 무시
        let minGap: TimeInterval = force ? 5 : 60
        if Date().timeIntervalSince(lastFetch ?? .distantPast) < minGap { return }
        lastFetch = Date()
        switch await service.fetch(from: oauth) {
        case .success(let u):
            usage = u
            error = nil
            // 오늘 5h 피크를 창 슬롯별로 누적 (Usage 탭 히트맵용)
            if let fh = u.fiveHour {
                UsageHistory.record(pct: fh.pct, resetsAt: fh.resetsAt, pingTimes: pingTimes)
                // Cloud 모드: 창 시작 역산 → 핑 슬롯 근처면 Pace log 에 auto 기록
                if pingMode == "cloud", let r = fh.resetsAt { recordAutoPing(resetsAt: r) }
            }
        case .failure(let e):
            error = e.description
        }
        usageHistory = UsageHistory.load()
        updatedAt = Date()
    }

    /// Cloud 발화 추정 — 5h 창 시작(resets−5h)이 핑 슬롯 근처면 Pace log 에 auto 로 기록.
    private func recordAutoPing(resetsAt: Date) {
        let start = resetsAt.addingTimeInterval(-5 * 3600)
        let slot = UsageHistory.slotName(for: resetsAt, pingTimes: pingTimes)
        let cal = Calendar.current
        let startMin = cal.component(.hour, from: start) * 60 + cal.component(.minute, from: start)
        let p = slot.split(separator: ":")
        let slotMin = (Int(p.first ?? "0") ?? 0) * 60 + (p.count > 1 ? (Int(p[1]) ?? 0) : 0)
        // 창 시작이 슬롯과 90분 이내일 때만 (엉뚱한 시각의 사용자 작업은 제외)
        guard abs(startMin - slotMin) <= 90 else { return }
        PingLog.appendIfAbsent(date: PingCalendar.dateStr(start), slot: slot, status: "auto", ts: start)
        pings = PingLog.load()
    }
}

/// 드롭다운: 탭(블립 이력 / 사용량 히트맵) + 도넛 게이지.
struct MenuContent: View {
    @ObservedObject var model: UsageModel
    var onPingLog: () -> Void = {}
    var onSettings: () -> Void = {}
    @State private var tab = 0
    @AppStorage("pacerLang") private var lang = "en"
    @AppStorage("routineHealthy") private var routineHealthy = true

    /// 이번 달 주 수에 맞춘 캘린더 영역 높이 (두 탭 공통 → 탭 전환 시 흔들림 없음).
    private var calendarHeight: CGFloat {
        let cal = Calendar.current
        let now = Date()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let days = cal.range(of: .day, in: .month, for: now)!.count
        let leading = cal.component(.weekday, from: monthStart) - 1
        let weeks = Int(ceil(Double(leading + days) / 7.0))
        return CGFloat(weeks) * 41 + 44 // 행(셀32+간격9) + 요일헤더 + 범례
    }

    /// 카드 본문 — usage 가 없어도 골격(캘린더 · 초기값 도넛)을 그린다.
    private var cardBody: some View {
        VStack(spacing: 9) {
            // 브랜드 워드마크 (Pacer 각인)
            Image("Wordmark").resizable().scaledToFit().frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: $tab) {
                Text(tr(lang, "Pace", "페이스")).tag(0)
                Text(tr(lang, "Usage", "사용량")).tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().tint(.pacerPurple)

            HStack {
                Text(Self.monthLabel(lang)).font(.system(size: 13, weight: .semibold))
                Spacer()
                if tab == 0 {
                    Button(action: onPingLog) {
                        Text(tr(lang, "Pace log ›", "페이스 로그 ›")).font(.system(size: 11)).foregroundStyle(Color.pacerPurple)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(tr(lang, "peak per 5h window", "5시간 창별 피크"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            ZStack(alignment: .top) {
                if tab == 0 {
                    PingCalendar(pingTimes: model.pingTimes, pings: model.pings, holidays: model.holidays)
                } else {
                    UsageHeatmap(history: model.usageHistory, pingTimes: model.pingTimes)
                }
            }
            .frame(height: calendarHeight, alignment: .top)   // 탭 전환 시 높이 고정 (캘린더/히트맵 동일)
            .padding(.top, 6)        // 년·월 라인 ↔ 요일 라인 간격

            Divider()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)   // 구분선 위아래 여백

            // Plan(좌) + 모드 배지(우) 한 줄
            HStack(spacing: 8) {
                if let plan = model.plan {
                    (Text(tr(lang, "Plan: ", "플랜: ")).foregroundStyle(.secondary)
                        + Text(plan).foregroundStyle(Color.claudeOrange))
                        .font(.system(size: 11, weight: .semibold))
                }
                Spacer()
                modeChip
            }

            HStack(spacing: 32) {
                DonutGauge(pct: model.usage?.fiveHour?.pct ?? 0, label: tr(lang, "5-Hour", "5시간"), sub: Self.remaining(model.usage?.fiveHour?.resetsAt, lang))
                DonutGauge(pct: model.usage?.sevenDay?.pct ?? 0, label: tr(lang, "7-Day", "7일"), sub: Self.remaining(model.usage?.sevenDay?.resetsAt, lang))
            }
            // plan/모드 라인 ↔ 도넛 사이 공간 (사용자 요청 — 이 라인을 띄움)
            .padding(.top, 20)
        }
    }

    /// 핑 방식 배지 — Local(초록) / Cloud 정상(파랑) / Cloud 끊김(회색).
    private var modeChip: some View {
        let isCloud = model.pingMode == "cloud"
        let c: Color
        let icon: String
        let label: String
        if !isCloud {
            c = .green; icon = "desktopcomputer"; label = tr(lang, "Local mode", "로컬 모드")
        } else if routineHealthy {
            c = .blue; icon = "cloud.fill"; label = tr(lang, "Cloud mode", "클라우드 모드")
        } else {
            c = .gray; icon = "cloud.fill"; label = tr(lang, "Cloud · check", "클라우드 · 확인 필요")
        }
        return HStack(spacing: 3) {
            Image(systemName: icon)
            Text(label)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(c)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(c.opacity(0.18), in: Capsule())
    }

    /// 사용량 미수신 시 카드 위 상태 배너 (큰 에러 대신 "갱신 중" 느낌).
    private var statusBanner: some View {
        HStack(spacing: 5) {
            Image(systemName: model.error != nil ? "exclamationmark.arrow.circlepath" : "arrow.triangle.2.circlepath")
            Text(model.error != nil ? tr(lang, "Couldn't update · tap Refresh", "갱신 실패 · 새로고침") : tr(lang, "Updating…", "갱신 중…"))
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// 토큰 만료/인증 실패 시 복구 카드 — 브라우저 재로그인(OAuth) 유도, 터미널 `claude` 는 폴백.
    private var connectionHelpCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(tr(lang, "Can't reach Claude Code", "Claude Code 연결을 확인할 수 없어요"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
            }
            Text(tr(lang, "Sign in again to refresh your token.", "다시 로그인해 토큰을 갱신하세요."))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            // 주 동작 — 브라우저 재로그인
            Button(action: { Task { await model.login() } }) {
                HStack(spacing: 6) {
                    if model.loggingIn { ProgressView().controlSize(.small) }
                    Text(model.loggingIn ? tr(lang, "Signing in…", "로그인 중…") : tr(lang, "Sign in to Claude", "Claude 로그인"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.pacerPurple)
            .disabled(model.loggingIn)
            // fallback — 터미널 직접 실행 + 토큰 재확인
            HStack(spacing: 8) {
                Button(tr(lang, "Copy `claude`", "`claude` 복사")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("claude", forType: .string)
                }
                Button(tr(lang, "Retry", "다시 시도")) { Task { await model.refresh(force: true) } }
                Spacer()
            }
            .font(.system(size: 11))
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }

    var body: some View {
        Group {
            if !model.loginGate {
                VStack(spacing: 12) {
                    // 토큰 만료/인증 실패: stale 토큰 → 복구 카드(재로그인 + 터미널 폴백)
                    if model.needsConnectionHelp {
                        connectionHelpCard
                    }
                    // 카드(캘린더·도넛)는 항상 그린다. 사용량을 못 받으면(429 등) 흐리게 + 상태 배너만.
                    cardBody
                        .opacity(model.usage == nil ? 0.4 : 1)
                        .overlay(alignment: .center) {
                            // 일시적 갱신 실패(usage 존재)일 때만 배너. 첫 설치 실패는 위 복구 카드가 담당.
                            if model.usage == nil && !model.needsConnectionHelp { statusBanner }
                        }

                    Divider()
                    HStack {
                        Button(tr(lang, "Refresh", "새로고침")) { Task { await model.refresh(force: true) } }
                        Button(tr(lang, "Settings", "설정")) { onSettings() }
                        Spacer()
                        Button(tr(lang, "Quit", "종료")) { NSApplication.shared.terminate(nil) }
                    }
                }
            } else {
                // 로그인 게이트 — 첫 실행(authPassed=false) 또는 토큰 미감지 → 로그인 화면
                OnboardingView(
                    isLoggingIn: model.loggingIn,
                    loginURL: model.loginURL,
                    onLogin: { Task { await model.login() } },
                    onCancel: { model.cancelLogin() },
                    onRetry: { Task { await model.refresh(force: true) } })
            }
        }
        .padding(16)
        .frame(width: 348)
        .background(Color(red: 0.11, green: 0.11, blue: 0.125)) // 불투명 다크 — 팝오버 반투명 비침 방지
        .task { await model.refresh() }
    }

    /// 월 표기 — "2026.06 (June)" / "2026.06 (6월)".
    static func monthLabel(_ lang: String) -> String {
        let now = Date()
        let ym = DateFormatter()
        ym.dateFormat = "yyyy.MM"
        let mon = DateFormatter()
        mon.locale = Locale(identifier: lang == "ko" ? "ko_KR" : "en_US")
        mon.dateFormat = "MMMM"
        return "\(ym.string(from: now)) (\(mon.string(from: now)))"
    }

    /// 리셋까지 남은 시간 (값만 — DonutGauge 가 시계 아이콘과 함께 표시).
    static func remaining(_ date: Date?, _ lang: String) -> String {
        guard let date else { return tr(lang, "no data", "데이터 없음") }
        let secs = Int(date.timeIntervalSinceNow)
        if secs <= 0 { return tr(lang, "resetting", "리셋 중") }
        let mins = secs / 60
        let (h, m) = (mins / 60, mins % 60)
        if h >= 24 { return tr(lang, "\(h / 24)d \(h % 24)h", "\(h / 24)일 \(h % 24)시간") }
        if h > 0 { return tr(lang, "\(h)h \(m)m", "\(h)시간 \(m)분") }
        return tr(lang, "\(m)m", "\(m)분")
    }
}
