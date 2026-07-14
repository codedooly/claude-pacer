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
    private var doctorWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // launchd 가 `Pacer --ping` 으로 부르면 핑만 쏘고 종료
        if CommandLine.arguments.contains("--ping") {
            PingRunner.run()
            NSApp.terminate(nil)
            return
        }
        // 전역 다크 고정 — Pacer 는 다크 디자인. 설정·닥터·페이스로그 창이 시스템 라이트 외관을 따라가면
        // 다크 튜닝 색과 섞여 흐릿/검정-on-검정이 되므로 모든 창을 다크로 통일 (팝오버·다이얼로그는 이미 다크 고정)
        NSApp.appearance = NSAppearance(named: .darkAqua)

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

        // 새 기능 1회 안내 — Fable 트래킹 (설정에 토글만 추가되면 존재를 모르므로 첫 실행에 한 번 안내)
        showFableIntroOnce()
    }

    /// Fable 트래킹 1회성 안내 팝업 — 로그인 완료 사용자에게만, 평생 1회. [설정 열기]로 토글 위치까지 연결.
    private func showFableIntroOnce() {
        let key = "fableIntroShown"
        guard !UserDefaults.standard.bool(forKey: key), Config.load().authPassed == true else { return }
        let lang = UserDefaults.standard.string(forKey: "pacerLang") ?? "en"
        // 앱 초기화(팝오버·게이지)와 겹치지 않게 잠깐 뒤에
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            UserDefaults.standard.set(true, forKey: key)
            PacerDialog.show(
                title: tr(lang, "New: Fable tracking", "새 기능: Fable 트래킹"),
                message: tr(lang,
                    "Fable now has its own weekly quota. Turn on “Fable tracking” in Settings — pings will open the Fable weekly window on schedule and keep its gauge visible. (Cloud mode: press Update/Apply to sync the routine.)",
                    "Fable 에 전용 주간 쿼터가 생겼어요. 설정에서 “Fable 트래킹”을 켜면 핑이 Fable 주간 창을 예약 시각에 열고 게이지도 상시 표시됩니다. (클라우드 모드는 갱신/적용 버튼으로 루틴에 반영)"),
                buttons: [(tr(lang, "Later", "나중에"), false),
                          (tr(lang, "Open Settings", "설정 열기"), true)]) { [weak self] idx in
                if idx == 1 { self?.openSettings() }
            }
        }
    }

    private func updateTitle() {
        let pct = model.usage?.fiveHour.map { " \($0.pct)%" } ?? ""
        statusItem.button?.attributedTitle = NSAttributedString(
            string: pct, attributes: [.font: NSFont.systemFont(ofSize: 12)]) // 메뉴바 기본보다 작게
        updateBadge()
    }

    /// 새 버전 알림 — 아이콘 우상단에 작은 보라 배지 점 (템플릿 아이콘은 그대로, 점만 별도 subview 오버레이).
    private var badgeDot: NSView?
    private func updateBadge() {
        guard let btn = statusItem.button else { return }
        if model.availableUpdate != nil {
            let dot = badgeDot ?? {
                let d = NSView()
                d.wantsLayer = true
                d.layer?.backgroundColor = NSColor(red: 0.698, green: 0.353, blue: 0.941, alpha: 1).cgColor
                d.layer?.cornerRadius = 3
                btn.addSubview(d)
                badgeDot = d
                return d
            }()
            dot.frame = NSRect(x: 11, y: btn.bounds.height - 9, width: 6, height: 6)   // 아이콘(leading) 우상단
        } else {
            badgeDot?.removeFromSuperview()
            badgeDot = nil
        }
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
        // 닥터(자가진단) — 업데이트 위로(업데이트는 배너·아이콘 배지·닥터 내부에서도 노출되므로 하위). 이어서 계정·유지보수
        menu.addItem(.separator())
        menu.addItem(withTitle: tr(lang, "Doctor", "닥터"), action: #selector(menuDoctor), keyEquivalent: "")
        menu.addItem(withTitle: tr(lang, "Update…", "업데이트…"), action: #selector(menuUpdate), keyEquivalent: "")
        menu.addItem(withTitle: tr(lang, "Re-login", "재로그인"), action: #selector(menuRelogin), keyEquivalent: "")
        // 지원 그룹 — 도움말·(디버그) 팝업체크
        menu.addItem(.separator())
        menu.addItem(withTitle: tr(lang, "Help", "도움말"), action: #selector(menuHelp), keyEquivalent: "")
        #if PACER_DEBUG
        // 디버그 전용 — 팝업 체크 창(디자인·언어 토글 확인). 릴리즈 빌드엔 미포함
        menu.addItem(withTitle: "🧪 팝업 체크", action: #selector(openDebugPopups), keyEquivalent: "")
        #endif
        menu.addItem(.separator())
        menu.addItem(withTitle: tr(lang, "Quit", "종료"), action: #selector(menuQuit), keyEquivalent: "")
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
    @objc private func menuDoctor() { openDoctor() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

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
            w.collectionBehavior = [.moveToActiveSpace]   // 현재 데스크탑으로 따라옴
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
            aboutWindow = w
        }
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let w = aboutWindow { positionUpperCenter(w) }   // 매 오픈 현재 데스크탑 중앙 상단
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

    /// 창을 현재 데스크탑(마우스가 있는 화면) 중앙 상단에 배치 — 정중앙보다 위(세로 62% 지점).
    private func positionUpperCenter(_ w: NSWindow) {
        w.contentView?.layoutSubtreeIfNeeded()   // 콘텐츠 크기 확정 후 좌표 계산
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let vis = screen?.visibleFrame else { w.center(); return }
        let wf = w.frame
        w.setFrameOrigin(NSPoint(x: vis.midX - wf.width / 2,
                                 y: vis.minY + vis.height * 0.70 - wf.height / 2))
    }

    @objc private func togglePopover() {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            // 팝오버 창을 key 로 — 세그먼트 탭 등 컨트롤이 활성색(회색 아님)으로 그려지도록
            popover.contentViewController?.view.window?.makeKey()
            model.popoverOpenNonce += 1   // 캘린더를 이번 달로 리셋 (재사용 뷰라 onDisappear 미발화 대비)
            model.checkUpdateIfStale()    // 6시간 지났으면 새 버전 확인 — 실행 직후 나온 릴리즈도 곧 배너로
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
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.moveToActiveSpace]   // 현재 보는 데스크탑으로 창이 따라옴 (Space 점프 방지)
            // 종료한 위치에서 다시 오픈 — 저장된 프레임 복원, 없으면 중앙 (앱 재실행 후에도 유지)
            if !w.setFrameUsingName("PacerPingLog") { w.center() }
            w.setFrameAutosaveName("PacerPingLog")
            pingLogWindow = w
        }
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        pingLogWindow?.makeKeyAndOrderFront(nil)
    }

    /// Pacer Doctor — claude·토큰·루틴·사용량 진단 화면. 매 오픈마다 새 모델로 최신 점검.
    private func openDoctor() {
        let lang = UserDefaults.standard.string(forKey: "pacerLang") ?? "en"
        if doctorWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.moveToActiveSpace]   // 현재 보는 데스크탑으로 따라옴
            // 종료한 위치에서 다시 오픈 — 저장된 프레임 복원, 없으면 중앙
            if !w.setFrameUsingName("PacerDoctor") { w.center() }
            w.setFrameAutosaveName("PacerDoctor")
            doctorWindow = w
        }
        // 매 오픈마다 새 DoctorModel — 재사용 창의 stale 진단 방지 (.task 가 다시 점검)
        doctorWindow?.title = tr(lang, "Pacer Doctor", "Pacer 닥터")
        let host = NSHostingController(rootView: DoctorView(model: DoctorModel(usage: model)))
        host.sizingOptions = [.preferredContentSize]
        doctorWindow?.contentViewController = host
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        doctorWindow?.makeKeyAndOrderFront(nil)   // center() 제거 → 마지막 위치 유지
    }
}

/// 메뉴 표시용 상태 + 갱신 로직.
@MainActor
final class UsageModel: ObservableObject {
    @Published var usage: Usage?
    @Published var plan: String?
    @Published var error: String?
    @Published var popoverOpenNonce = 0   // 팝오버 열 때마다 +1 → 캘린더를 이번 달로 리셋하는 신호
    @Published var updatedAt: Date?
    @Published var pings: [String: String] = [:]
    @Published var usageHistory: [String: [String: Int]] = [:]

    @Published var pingTimes: [String] = Config.load().pingTimes
    @Published var pingMode: String = Config.load().mode
    @Published var holidays: Set<Date> = []
    @Published var skipWeekends: Bool = false   // Local+주말스킵일 때만 true (캘린더 off 표시용. Cloud 는 매일 발사)
    @Published var authed: Bool = true
    @Published var availableUpdate: String?   // 최신 릴리즈가 현재보다 새 버전이면 그 버전(배너·아이콘 점). 없으면 nil
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
    private var resettingRetries = 0   // 리셋 경계 stale 시 자동 재조회 횟수 (무한 루프 방지, 최대 3)
    private var pollTimer: Timer?
    private var updateTimer: Timer?

    init() {
        authed = service.hasCredentials()
        Task { await refresh() }
        // 신규 버전 알림 — 실행 시 1회 + 하루마다 (메뉴바 앱은 며칠씩 떠 있으니 타이머도 필요. 같은 버전은 상태값이라 나그 X)
        Task { await checkUpdate() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkUpdate() }
        }
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

    /// 최신 릴리즈 확인 → 현재보다 새 버전이면 availableUpdate 설정 (배너·아이콘 점 표시).
    func checkUpdate() async {
        lastUpdateCheck = Date()
        let cur = Updater.currentVersion()
        if let latest = await Updater.latestVersion(), Updater.isNewer(latest, than: cur) {
            availableUpdate = latest
        } else {
            availableUpdate = nil
        }
    }

    private var lastUpdateCheck: Date?

    /// 팝오버 열 때 호출 — 마지막 확인이 6시간 이상 지났으면 재확인 (실행 직후 나온 릴리즈도 24h 타이머 전에 배너 노출).
    func checkUpdateIfStale() {
        guard Date().timeIntervalSince(lastUpdateCheck ?? .distantPast) > 6 * 3600 else { return }
        Task { await checkUpdate() }
    }

    /// resets_at 이 과거인 창이 하나라도 있으면 true — 리셋 경계 순간(API 가 1~2분간 stale) 감지용.
    /// scoped(Fable 등)의 resets_at nil(미사용)은 resetting 아님.
    static func isResetting(_ u: Usage) -> Bool {
        func past(_ w: UsageWindow?) -> Bool {
            guard let r = w?.resetsAt else { return false }
            return r.timeIntervalSinceNow <= 0
        }
        if past(u.fiveHour) || past(u.sevenDay) { return true }
        return u.weeklyScoped.contains { ($0.resetsAt?.timeIntervalSinceNow ?? 1) <= 0 }
    }

    func refresh(force: Bool = false) async {
        // Keychain(security 서브프로세스)을 refresh 당 1회만 읽어 authed·plan·fetch 로 전달
        let oauth = service.oauthDict()
        authed = service.hasCredentials(from: oauth)   // 토큰 생기면 온보딩 → 메인 전환
        // config(모드·핑·공휴일·로그)는 쿨다운과 무관하게 매번 즉시 반영 — 설정 변경이 바로 보이게
        let cfg = Config.load()
        pingTimes = cfg.pingTimes
        pingMode = cfg.mode
        // Cloud 모드는 매일 발사(주말·공휴일 스킵 불가) → 캘린더에서 off 처리 안 함. Local 일 때만 스킵 반영.
        let localSkip = cfg.mode == "local"
        holidays = (localSkip && cfg.skipHolidays) ? KoreanHolidays.holidays(year: Calendar.current.component(.year, from: Date())) : []
        skipWeekends = localSkip && cfg.skipWeekends
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
            // 리셋 경계 순간: resets_at 이 과거(=resetting)면 API 가 1~2분간 stale.
            // 사용자가 아무것도 안 해도 매끄럽게 정상화되도록 45초 뒤 자동 재조회(최대 3회). 정상화되면 카운터 리셋.
            if Self.isResetting(u) {
                if resettingRetries < 3 {
                    resettingRetries += 1
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 45_000_000_000)
                        await self?.refresh(force: true)
                    }
                }
            } else {
                resettingRetries = 0
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
/// 게이지 호버 상태 — 어느 게이지(index) 위에 어떤 설명(text) 말풍선을 띄울지.
struct GaugeHover: Equatable {
    let index: Int
    let text: String
}

/// 말풍선 아래 말꼬리 (▼).
struct BalloonTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct MenuContent: View {
    @ObservedObject var model: UsageModel
    var onPingLog: () -> Void = {}
    var onSettings: () -> Void = {}
    @State private var tab = 0
    @State private var monthOffset = 0   // 캘린더/히트맵 표시 월 (0=이번 달, -1=지난 달 …). 데이터 없는 달은 빈 캘린더
    @State private var gaugeHover: GaugeHover?   // 게이지 라벨 호버 → 테마 말풍선 (index=게이지 위치, text=설명)
    @AppStorage("pacerLang") private var lang = "en"
    @AppStorage("routineHealthy") private var routineHealthy = true

    /// 이번 달 주 수에 맞춘 캘린더 영역 높이 (두 탭 공통 → 탭 전환 시 흔들림 없음).
    private var calendarHeight: CGFloat {
        let cal = Calendar.current
        let now = cal.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let days = cal.range(of: .day, in: .month, for: now)!.count
        let leading = cal.component(.weekday, from: monthStart) - 1
        let weeks = Int(ceil(Double(leading + days) / 7.0))
        return CGFloat(weeks) * 41 + 66 // 행(셀32+간격9) + 요일헤더 + 범례 + 범례 아래 여백(구분선과 안 겹치게)
    }

    /// 카드 본문 — usage 가 없어도 골격(캘린더 · 초기값 도넛)을 그린다.
    private var cardBody: some View {
        VStack(spacing: 14) {   // 로고·탭·날짜/이동·캘린더 라인 간 여유 (좁아 보이지 않게)
            // 브랜드 워드마크 (Pacer 각인)
            Image("Wordmark").resizable().scaledToFit().frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Pace/Usage 탭 — 콤팩트 캡슐 토글(가운데 정렬), 선택 쪽 보라 채움. 애플 캘린더 세그먼트 톤
            HStack(spacing: 4) {
                tabButton(tr(lang, "Pace", "페이스"), 0)
                tabButton(tr(lang, "Usage", "사용량"), 1)
            }
            .padding(3)
            .background(Color.white.opacity(0.06), in: Capsule())
            .animation(.easeInOut(duration: 0.15), value: tab)
            .padding(.top, -6)   // 로고 라인 ↔ 탭 라인 간격만 좁게 (아래 라인들은 여유 유지)

            HStack {
                // 월 라벨(좌) — 탭 → 이번 달 복귀
                Button(action: { monthOffset = 0 }) {
                    Text(Self.monthLabel(lang, monthOffset)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                Spacer()
                // Pace log — 목록 아이콘(옵션3, Pace 탭만). 텍스트 없이 아이콘화라 범례 줄 오버플로 없음
                if tab == 0 {
                    Button(action: onPingLog) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.pacerPurple)
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.06), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(tr(lang, "Pace log", "페이스 로그"))
                    .padding(.trailing, 6)
                }
                // 월 이동(우측 고정, Itsycal ◀ ● ▶) — 우측 앵커라 라벨 폭이 변해도 화살표 x 고정. ● = 오늘
                HStack(spacing: 3) {
                    monthNavButton("arrowtriangle.left.fill") { monthOffset -= 1 }
                    // 오늘 — 작은 텍스트 pill(애플 ‹ 오늘 › 스타일). 이번 달이면 흐리게 + 비활성
                    Button(action: { monthOffset = 0 }) {
                        Text(tr(lang, "Today", "오늘"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(monthOffset == 0 ? Color.secondary.opacity(0.4) : Color.pacerPurple)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(Color.white.opacity(0.06), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(monthOffset == 0)
                    monthNavButton("arrowtriangle.right.fill") { monthOffset += 1 }
                }
            }

            ZStack(alignment: .top) {
                if tab == 0 {
                    PingCalendar(pingTimes: model.pingTimes, pings: model.pings, holidays: model.holidays, skipWeekends: model.skipWeekends, monthOffset: monthOffset)
                } else {
                    UsageHeatmap(history: model.usageHistory, pingTimes: model.pingTimes, monthOffset: monthOffset)
                }
            }
            .frame(height: calendarHeight, alignment: .top)   // 탭 전환 시 높이 고정 (캘린더/히트맵 동일)
            .padding(.top, 4)        // 날짜/이동 라인 ↔ 요일 라인 간격 (상위 VStack spacing 14 와 합산)

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

            gaugeRow
                // plan/모드 라인 ↔ 도넛 사이 공간
                .padding(.top, 10)
        }
    }

    /// 사용량 게이지 행 — 세션(5h) + 주간 전체 + 주간 모델별(Fable 등).
    /// scoped 는 API limits 기반이라 모델이 늘면(예: Opus 전용 통) 도넛이 자동으로 하나 더 붙는다.
    private var gaugeRow: some View {
        // 표시 규칙: 트래킹 ON = 상시 표시 / OFF = Fable 창이 활성(사용량 또는 카운트다운)일 때만 — 미사용 상시 도넛 방지
        let fableOn = Config.load().fableOn
        var scoped = (model.usage?.weeklyScoped ?? []).filter { fableOn || $0.pct > 0 || $0.resetsAt != nil }
        #if PACER_DEBUG
        // 디자인 미리보기 — 트래킹 ON + 실데이터 없음일 때만 45% 목업 (실제 쿼터 소모 0). 릴리즈 빌드엔 미포함
        if fableOn, scoped.first(where: { $0.pct > 0 }) == nil {
            scoped = [ScopedLimit(name: "Fable", pct: 45, resetsAt: Date().addingTimeInterval(3 * 86400 + 5 * 3600))]
        }
        #endif
        let compact = !scoped.isEmpty          // 3개+ 이면 도넛 축소·간격 확보
        let size: CGFloat = compact ? 80 : 96
        let spacing: CGFloat = compact ? 16 : 32
        // 정체성 점(옵션2) — 채움 임계값과 안 겹치는 톤. 세션=블루, 주간전체=그린, 모델별=앰버/…
        let a5h = Color(red: 0.39, green: 0.78, blue: 0.98)
        let a7d = Color(red: 0.40, green: 0.85, blue: 0.60)
        let scopedAccents: [Color] = [Color(red: 1.0, green: 0.72, blue: 0.30), Color(red: 0.95, green: 0.55, blue: 0.78)]

        // 게이지 항목 일괄 구성 — (도넛 파라미터 + 호버 말풍선 문구)
        var items: [(pct: Int, label: String, sub: String, accent: Color, hollow: Bool, help: String)] = [
            (model.usage?.fiveHour?.pct ?? 0, tr(lang, "5-Hour", "5시간"),
             Self.remaining(model.usage?.fiveHour?.resetsAt, lang), a5h, false,
             tr(lang, "5-hour session window — shared across all models", "5시간 세션 창 — 모든 모델 공용")),
            (model.usage?.sevenDay?.pct ?? 0, tr(lang, "7-Day", "7일"),
             Self.remaining(model.usage?.sevenDay?.resetsAt, lang), a7d, false,
             tr(lang, "Weekly limit — all models combined", "주간 한도 — 모든 모델 합산")),
        ]
        // 주간 모델별(Fable 등) — 미사용(resetsAt nil)이면 "미사용".
        // 트래킹 OFF 인데 사용량이 잡히면(CLI 직접 사용) 빨간 테두리 점 — 호버 말풍선으로 트래킹 ON 유도
        for (i, s) in scoped.enumerated() {
            items.append((s.pct, s.name,
                          (s.pct == 0 && s.resetsAt == nil) ? tr(lang, "unused", "미사용") : Self.remaining(s.resetsAt, lang),
                          fableOn ? scopedAccents[i % scopedAccents.count] : Color.pacerRed,
                          !fableOn,
                          fableOn
                              ? tr(lang, "\(s.name) weekly window — Pacer pings keep it opening on schedule",
                                         "\(s.name) 주간 창 — 핑이 예약 시각에 창을 열어 정렬 중")
                              : tr(lang, "\(s.name) usage detected, but tracking is off — turn on “Fable tracking” in Settings so pings open the weekly window on schedule",
                                         "\(s.name) 사용량이 잡혔지만 트래킹은 꺼져 있어요 — 설정에서 “Fable 트래킹”을 켜면 핑이 주간 창을 예약 시각에 열어줍니다")))
        }

        return HStack(spacing: spacing) {
            ForEach(items.indices, id: \.self) { i in
                let it = items[i]
                DonutGauge(pct: it.pct, label: it.label, sub: it.sub, size: size,
                           accent: it.accent, accentHollow: it.hollow,
                           onHover: { h in
                               // 떠날 때는 내 말풍선일 때만 닫기 (이웃으로 이동 시 깜빡임 방지)
                               if h { gaugeHover = GaugeHover(index: i, text: it.help) }
                               else if gaugeHover?.index == i { gaugeHover = nil }
                           })
            }
        }
        // 테마 말풍선 — 라벨 호버 시 게이지 행 위로 (위 UI 를 잠시 덮어도 무방). 말꼬리는 해당 게이지 라벨을 가리킴.
        // if-let 조건 래퍼는 alignmentGuide 를 무시(라벨 덮는 버그)하므로 상시 배치 + opacity 로 표시 전환
        .overlay(alignment: .topLeading) {
            let centerX = CGFloat(gaugeHover?.index ?? 0) * (size + spacing) + size / 2
            helpBalloon(gaugeHover?.text ?? "", arrowX: centerX)
                .alignmentGuide(.top) { $0[.bottom] + 5 }   // 말꼬리 끝이 라벨 위 5pt — 텍스트를 덮지 않게
                .opacity(gaugeHover == nil ? 0 : 1)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.12), value: gaugeHover)
    }

    /// 테마 말풍선 — 다크 배경 + 보라 테두리 + 아래로 향한 말꼬리(arrowX 위치).
    private func helpBalloon(_ text: String, arrowX: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .frame(maxWidth: 270, alignment: .leading)
                .background(Color(red: 0.16, green: 0.15, blue: 0.19), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.pacerPurple.opacity(0.55), lineWidth: 1))
            // 말꼬리 — 게이지 라벨 중심(arrowX)을 가리키는 ▼
            BalloonTail()
                .fill(Color(red: 0.16, green: 0.15, blue: 0.19))
                .overlay(BalloonTail().stroke(Color.pacerPurple.opacity(0.55), lineWidth: 1))
                .frame(width: 14, height: 7)
                .padding(.leading, max(6, arrowX - 7))
        }
        .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
    }

    /// Pace/Usage 탭 한 칸 — 선택 시 보라 채움·흰 글자, 미선택은 회색. 풀폭(maxWidth) 분할.
    private func tabButton(_ title: String, _ index: Int) -> some View {
        Button(action: { tab = index }) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tab == index ? .white : Color.secondary)
                .padding(.horizontal, 22)
                .padding(.vertical, 5)
                .background(tab == index ? Color.pacerPurple : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 월 이동 버튼 — 28pt 원형(넉넉한 히트영역), 서브틀 배경. 눌림 반응 확실.
    private func monthNavButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.06), in: Circle())   // 애플 캘린더식 살짝 흐린 버튼 영역
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
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

    /// 새 버전 알림 배너 — 탭하면 업데이트 확인창 (현재→최신 화살표).
    private func updateBanner(_ version: String) -> some View {
        Button { Updater.runUpdate(latest: version) } label: {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                Text(tr(lang, "New version \(version) — Update", "새 버전 \(version) — 업데이트"))
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Image(systemName: "arrow.down.circle.fill")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.pacerPurple, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        Group {
            if !model.loginGate {
                VStack(spacing: 12) {
                    // 새 버전 알림 배너 — 있을 때만 (탭 → 업데이트 확인창)
                    if let v = model.availableUpdate { updateBanner(v) }
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
                        .padding(.top, 10)     // 도넛(시간) ↔ 구분선 위 여백
                        .padding(.bottom, 3)   // 구분선 ↔ 버튼 간격은 좁게 (하단 카드 여백과 균형)
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
        // 팝오버 열 때마다(nonce 증가) 이번 달로 리셋 — 재사용 호스팅이라 onDisappear 가 안 먹어 nonce 로 감지
        .onChange(of: model.popoverOpenNonce) { monthOffset = 0 }
    }

    /// 월 표기 — "2026.06 (June)" / "2026.06 (6월)".
    static func monthLabel(_ lang: String, _ offset: Int = 0) -> String {
        let now = Calendar.current.date(byAdding: .month, value: offset, to: Date()) ?? Date()
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
