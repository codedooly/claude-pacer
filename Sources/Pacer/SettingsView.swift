import SwiftUI

/// 설정 창 — 언어 + 핑 방식 + 시각 + skip + 로그인 자동 실행.
/// Cloud 모드는 Pacer 가 `claude -p "/pace-schedule"` 로 클라우드 routine 을 자동 등록/갱신/비활성화한다.
struct SettingsView: View {
    @State private var hours: [Int]
    @State private var skipWeekends: Bool
    @State private var skipHolidays: Bool
    @State private var mode: String   // "local"(launchd) | "cloud"(routine)
    @State private var initialMode: String   // 열었을 때 모드 (Done 시 변경 감지 → routine 1회 sync)
    @State private var window: NSWindow?
    @State private var routineLoading = false
    @State private var syncing = false        // Done 시 routine 동기화 카운트다운
    @State private var syncCountdown = 15
    @State private var syncError: String?     // Cloud 등록 실패 안내 (예: no_env). 성공 시 nil 로 클리어
    @AppStorage("pacerLang") private var lang = "en"
    @AppStorage("routineTimes") private var routineTimes = ""   // 등록된 routine 핑 시각 CSV. 빈 = 미등록
    @AppStorage("routineHealthy") private var routineHealthy = true   // 마지막 status 결과: 클라우드에 routine 존재+enabled
    @AppStorage("cloudEnvId") private var cloudEnvId = ""   // no_env 시 사용자가 `/schedule` 에서 붙여넣는 환경ID
    @State private var launchAtLogin = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/com.dooly.pacer.launch.plist")

    init() {
        let c = Config.load()
        _hours = State(initialValue: c.pingTimes.map { Int($0.split(separator: ":").first ?? "0") ?? 0 })
        _skipWeekends = State(initialValue: c.skipWeekends)
        _skipHolidays = State(initialValue: c.skipHolidays)
        _mode = State(initialValue: c.mode)
        _initialMode = State(initialValue: c.mode)
    }

    var body: some View {
        VStack(spacing: 0) {
        Form {
            // 핑 방식 — 하나만 활성해 Routine/launchd 중복 발사를 막는다
            Section {
                Picker("Method", selection: $mode) {
                    Text(tr(lang, "Local (launchd)", "로컬 (launchd)")).tag("local")
                    Text(tr(lang, "Cloud (Routine)", "클라우드 (Routine)")).tag("cloud")
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(maxWidth: .infinity)
                .tint(mode == "cloud" ? .blue : .green)
            } header: {
                HStack {
                    Text(tr(lang, "Ping method", "핑 방식"))
                    Spacer()
                    Button {
                        // 모드 변경 OR (Cloud에서) 핑 변경 → 동기화 후 닫기, 아니면 바로 닫기
                        let pingChanged = mode == "cloud" && !routineTimes.isEmpty && routineTimes != currentCSV
                        if mode != initialMode || pingChanged { startSyncAndClose() }
                        else { window?.performClose(nil) }
                    } label: {
                        if syncing {
                            // 완료 버튼 안에 카운트다운 (10→1), 그 뒤엔 스피너
                            if syncCountdown > 0 { Text("\(syncCountdown)").monospacedDigit() }
                            else { ProgressView().controlSize(.small) }
                        } else {
                            Text(tr(lang, "Done", "완료"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(syncing)
                }
            } footer: {
                Text(methodFooter)
            }

            Section {
                ForEach(hours.indices, id: \.self) { i in
                    HStack {
                        Picker(tr(lang, "Ping \(i + 1)", "핑 \(i + 1)"), selection: $hours[i]) {
                            // 앞 핑 + 5h 이후만 선택 가능 (5시간 리셋 기준)
                            ForEach(startHour(i)..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }
                        Button(role: .destructive) { hours.remove(at: i) } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .disabled(hours.count <= 1)
                    }
                }
                // 마지막 핑 + 5h 가 24시 안일 때만 추가 가능
                if hours.count < 5, let last = hours.max(), last + 5 < 24 {
                    Button { hours.append(last + 5) } label: { Label(tr(lang, "Add ping", "핑 추가"), systemImage: "plus") }
                }
            } header: {
                Text(tr(lang, "Ping times — when to open a fresh 5h window", "핑 시각 — 새 5시간 창을 여는 시점"))
            } footer: {
                Text(tr(lang,
                        "Each ping is ≥ 5h after the previous one — the window only resets every 5 hours, so closer pings do nothing.",
                        "각 핑은 앞 핑보다 5시간 이상 뒤입니다 — 창은 5시간마다만 리셋되니, 더 가까운 핑은 의미가 없어요."))
            }

            // Cloud 모드 — Pacer 가 routine 을 자동 등록/갱신 (복사-붙여넣기 없음)
            if mode == "cloud" {
                Section {
                    if routineLoading {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(tr(lang, "Syncing routine…", "routine 동기화 중…"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    } else {
                        Label(syncText, systemImage: syncIcon)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(syncColor)
                        // 끊김(웹 삭제 등) → 재등록 / 핑 변경 → 갱신
                        // 재등록/갱신(좌) + 웹 열기(우) — 가로 배치
                        HStack(spacing: 8) {
                            if !routineHealthy {
                                Button(tr(lang, "Re-register", "재등록")) { Task { await registerRoutine() } }
                                    .buttonStyle(.borderedProminent)
                                    .frame(maxWidth: .infinity)
                            } else if !routineTimes.isEmpty && routineTimes != currentCSV {
                                Button(tr(lang, "Update", "갱신")) { Task { await registerRoutine() } }
                                    .buttonStyle(.borderedProminent)
                                    .frame(maxWidth: .infinity)
                            }
                            Button(tr(lang, "Open web", "웹 열기")) { openRoutinesWeb() }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity)
                        }
                        // 클라우드 환경 없음(no_env) 등록 실패 안내 — 일반 실패와 구분
                        if let syncError {
                            Text(syncError)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // no_env 안내 중이거나 이미 env 를 입력한 경우 → 직접 붙여넣기 필드 노출 (다시 Done 누르면 이 env 로 등록)
                        if syncError != nil || !cloudEnvId.isEmpty {
                            TextField("env_...", text: $cloudEnvId)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                            Text(tr(lang,
                                    "Paste your environment ID from `/schedule`",
                                    "터미널 `/schedule` 에서 본 환경ID 를 붙여넣으세요"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } header: {
                    Text("Claude Routine")
                } footer: {
                    Text(tr(lang,
                            "Pacer registers a cloud routine via Claude Code — runs even when your Mac is off.",
                            "Pacer 가 Claude Code 로 클라우드 routine 을 등록합니다 — 맥북이 꺼져 있어도 실행됩니다."))
                }
            }

            // 주말·공휴일 스킵 — Local 은 토글, Cloud 는 매일 발화 안내 (같은 위치)
            if mode == "local" {
                Section {
                    Toggle(tr(lang, "Skip weekends", "주말 건너뛰기"), isOn: $skipWeekends).tint(.pacerPurple)
                    Toggle(tr(lang, "Skip holidays (KR)", "공휴일 건너뛰기 (한국)"), isOn: $skipHolidays).tint(.pacerPurple)
                } footer: {
                    Text(tr(lang,
                            "On = skip weekends / Korean holidays — no work those days, so no window to open.",
                            "켜면 주말·한국 공휴일엔 핑을 건너뜁니다 — 쉬는 날엔 굳이 창을 열 필요가 없으니까요."))
                }

                // Local — 절전 방지 안내 (맥북 잠들면 핑이 안 나감)
                Section {
                    HStack {
                        Text("sudo pmset -c disablesleep 1")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        Button { copyCmd("sudo pmset -c disablesleep 1") } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text(tr(lang, "Keep your Mac awake", "맥북 잠들지 않게"))
                } footer: {
                    Text(tr(lang,
                            "Pings won't fire while your Mac sleeps. Run this in Terminal to stay awake even with the lid closed (on power). Needs your password.",
                            "맥북이 잠들면 핑이 나가지 않아요. 터미널에서 실행하면 덮개를 닫아도 (전원 연결 시) 깨어 있습니다. 비밀번호가 필요해요."))
                }
            } else {
                Section {
                    Label(tr(lang,
                             "Fires daily — weekends and holidays included. (Cloud routines can't skip specific days.)",
                             "주말·공휴일 포함 매일 발화합니다. (Cloud routine 은 특정 날을 건너뛸 수 없어요.)"),
                          systemImage: "calendar")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(tr(lang, "Launch at login", "로그인 시 자동 실행"), isOn: $launchAtLogin).tint(.pacerPurple)
            } footer: {
                Text(tr(lang, "Start Pacer automatically when you log in.", "로그인하면 Pacer 를 자동으로 시작합니다."))
            }

            Section {
                Button(tr(lang, "Reset to defaults (08:00 · 13:00 · 18:00)", "기본값으로 초기화 (08:00 · 13:00 · 18:00)")) { resetDefaults() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            } footer: {
                Text(tr(lang,
                        "Up to 5 pings/day — a day fits about 24h ÷ 5h ≈ 4.8 windows.",
                        "하루 최대 5개 — 24시간 ÷ 5시간 ≈ 4.8개 창."))
            }

            // 언어 토글 — 맨 아래 (즉시 전 화면 반영)
            Section {
                Picker("Language", selection: $lang) {
                    Text("English").tag("en")
                    Text("한국어").tag("ko")
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(maxWidth: .infinity)
            } header: {
                Text(tr(lang, "Language", "언어"))
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.hidden)   // 회색 스크롤바 숨김 (스크롤은 그대로 동작)
        .disabled(routineLoading)   // routine 동기화 중엔 전체 잠금
        }
        .tint(.pacerPurple)
        .frame(width: 380, height: clampedHeight) // 가로 + 내용 높이(화면 넘으면 클램프)
        .background(WindowAccessor { w in
            window = w
            w.level = .floating
            w.collectionBehavior = [.moveToActiveSpace]   // 현재 보는 데스크탑으로 (Space 점프 방지)
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        })
        .onChange(of: hours) { normalizeHours(); save(mode: initialMode) }
        .onChange(of: skipWeekends) { save(mode: initialMode) }
        .onChange(of: skipHolidays) { save(mode: initialMode) }
        // mode 는 Done 시에만 확정 저장 — X 닫기로 종료하면 기존 모드 유지
        .onChange(of: launchAtLogin) { setLaunchAtLogin(launchAtLogin) }
        // 동기화 중엔 창 닫기 버튼 비활성 (작업 중단·중복 방지)
        .onChange(of: routineLoading) { window?.standardWindowButton(.closeButton)?.isEnabled = !routineLoading }
        .onChange(of: syncing) { window?.standardWindowButton(.closeButton)?.isEnabled = !syncing }
        // 열 때마다 현재 config 모드로 탭 동기화 (X 닫기로 임시 전환이 남지 않게 — 창이 재사용되므로)
        .onAppear {
            let c = Config.load()
            hours = c.pingTimes.map { Int($0.split(separator: ":").first ?? "0") ?? 0 }
            skipWeekends = c.skipWeekends
            skipHolidays = c.skipHolidays
            mode = c.mode
            initialMode = c.mode
        }
        // 설정 열 때 클라우드 routine 실제 상태 백그라운드 확인 (웹 삭제 등 감지)
        .task { if mode == "cloud" { await checkRoutineHealth() } }
    }

    /// 창 높이 (모드/등록 상태별).
    private var settingsHeight: Int {
        if mode == "cloud" { return 810 }   // 웹 열기 버튼 추가분
        return 840                          // Local — routine 섹션 제거로 단축
    }

    /// 콘텐츠 높이 — 단 화면(14" 등)을 넘으면 화면 높이로 클램프 (잘림 방지, 내부 스크롤).
    private var clampedHeight: CGFloat {
        let content = CGFloat(settingsHeight + hours.count * 60)
        let screen = ((NSScreen.main?.visibleFrame.height) ?? 900) - 48
        return min(content, screen)
    }

    // MARK: - Routine (claude -p 경유)

    /// Done — 확정 저장 + routine 동기화(카운트다운 오버레이) 후 창 닫기. (즉시 닫지 않아 재오픈 깜빡임 없음)
    private func startSyncAndClose() {
        Task { @MainActor in
            syncing = true
            syncCountdown = 15
            // 15초 카운트다운 — 0 이 되면 스피너로 전환 (그 이상 걸리는 경우)
            let counter = Task { @MainActor in
                for i in stride(from: 15, through: 1, by: -1) {
                    syncCountdown = i
                    try? await Task.sleep(for: .seconds(1))
                }
                syncCountdown = 0
            }
            // config 저장은 sync 성공 시에만 (registerRoutine/disable 내부) — 타임아웃·실패 시 기존 모드 유지
            _ = await syncRoutineForMode()
            counter.cancel()
            syncing = false
            window?.standardWindowButton(.closeButton)?.isEnabled = true
            window?.performClose(nil)
        }
    }

    /// 모드 전환 시 routine 동기화 — Cloud 면 등록/활성, Local 이면 비활성화. 성공해야 config 확정.
    @discardableResult
    private func syncRoutineForMode() async -> Bool {
        if mode == "cloud" {
            // 핑 변경 없고 이미 등록돼 있으면 enable(가벼움), 실패(웹삭제 등)·핑 변경이면 register(전체)
            if !routineTimes.isEmpty && routineTimes == currentCSV {
                if await enableRoutine() { return true }
            }
            return await registerRoutine()
        } else {
            routineLoading = true
            let r = await RoutineService.run("disable")   // 비활성(중복 방지). routineTimes 는 재활성 위해 유지
            let ok = r?.ok ?? false
            if ok { save(mode: mode); initialMode = mode }   // 성공 시에만 config 확정
            routineLoading = false
            return ok
        }
    }

    /// routine 활성화만 (enable) — 핑 변경 없을 때 가벼운 동기화.
    @discardableResult
    private func enableRoutine() async -> Bool {
        routineLoading = true
        let r = await RoutineService.run("enable")
        let ok = r?.ok ?? false
        if ok {
            routineHealthy = true
            save(mode: mode); initialMode = mode
        }
        routineLoading = false
        return ok
    }

    /// routine 등록/갱신 (현재 핑 시각). 성공 시에만 config·상태 확정.
    @discardableResult
    private func registerRoutine() async -> Bool {
        routineLoading = true
        let times = hours.sorted().map { String(format: "%02d:00", $0) }
        // cloudEnvId 비어있으면 빈 문자열 → 스킬이 환경 자동탐지. 있으면 그 env 로 최우선 등록.
        let r = await RoutineService.run("register", times: times, env: cloudEnvId.trimmingCharacters(in: .whitespaces))
        let ok = r?.ok ?? false
        if ok {
            syncError = nil
            routineTimes = currentCSV
            routineHealthy = true
            save(mode: mode)        // 성공 시에만 config 확정 (실패·타임아웃 시 불일치 방지)
            initialMode = mode
        } else if r?.reason == "no_env" {
            // 클라우드 환경(trigger) 0개 — 신규 사용자. 일반 실패와 구분되는 명확한 안내
            syncError = tr(lang,
                "No cloud environment found — run `claude`, open `/schedule` once to create one, then retry.",
                "클라우드 환경이 없습니다 — 터미널에서 `claude` 실행 후 `/schedule` 을 한 번 띄워 환경을 만든 뒤 다시 시도하세요.")
        } else {
            // 그 외 실패 → 실제 에러(404 등)를 NSAlert 로 노출해 사용자가 접수 가능하게
            let alert = NSAlert()
            alert.messageText = tr(lang, "Cloud registration failed", "Cloud 등록 실패")
            alert.informativeText = r?.errorDetail ?? syncError ?? "unknown"
            alert.runModal()
        }
        routineLoading = false
        return ok
    }

    /// 클라우드 routine 실제 상태 확인 (status) → routineHealthy 갱신. 백그라운드(로딩 표시 X).
    private func checkRoutineHealth() async {
        let r = await RoutineService.run("status")
        routineHealthy = (r?.ok == true) && !((r?.id.isEmpty) ?? true) && (r?.enabled == true)
    }

    /// 핑 i 의 최소 선택 시각 (앞 핑 + 5h).
    private func startHour(_ i: Int) -> Int {
        i == 0 ? 0 : min(hours[i - 1] + 5, 23)
    }

    /// 핑들을 오름차순 + 5시간 간격으로 정규화 (수정으로 간격이 깨지면 뒤 핑을 민다).
    private func normalizeHours() {
        guard hours.count > 1 else { return }
        var h = hours.sorted()
        for i in 1..<h.count where h[i] < h[i - 1] + 5 {
            h[i] = h[i - 1] + 5
        }
        h = h.filter { $0 < 24 }   // 24시 넘게 밀린 핑은 제거
        if h != hours { hours = h }   // 변경 시에만 (재귀 방지)
    }

    /// 현재 핑 시각 CSV ("08:00,13:00,18:00").
    private var currentCSV: String {
        hours.sorted().map { String(format: "%02d:00", $0) }.joined(separator: ",")
    }

    /// 등록 상태 문구.
    private var syncText: String {
        if !routineHealthy {
            return tr(lang, "Routine not found in the cloud — re-register it.", "클라우드에 routine 이 없어요 — 다시 등록하세요.")
        }
        if routineTimes.isEmpty {
            return tr(lang, "Not registered yet — switching to Cloud registers it.", "아직 등록 안 됨 — Cloud 로 전환하면 등록됩니다.")
        }
        if routineTimes != currentCSV {
            return tr(lang, "Ping times changed — tap Update to sync the routine.", "핑 시각이 바뀌었습니다 — Update 를 눌러 routine 을 갱신하세요.")
        }
        return tr(lang, "Routine registered — runs at your ping times.", "routine 등록됨 — 핑 시각에 실행됩니다.")
    }

    private var syncColor: Color {
        if !routineHealthy { return .red }
        if routineTimes.isEmpty || routineTimes != currentCSV { return .orange }
        return .pacerPurple
    }

    private var syncIcon: String {
        if !routineHealthy { return "exclamationmark.octagon.fill" }
        if routineTimes.isEmpty || routineTimes != currentCSV { return "exclamationmark.triangle.fill" }
        return "checkmark.seal.fill"
    }

    private func openRoutinesWeb() {
        if let url = URL(string: "https://claude.ai/code/routines") { NSWorkspace.shared.open(url) }
    }

    private func copyCmd(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: - Login item

    /// 로그인 자동 실행 — LaunchAgent plist 생성/제거 (RunAtLoad). unsigned 빌드도 동작.
    private func setLaunchAtLogin(_ on: Bool) {
        let path = NSHomeDirectory() + "/Library/LaunchAgents/com.dooly.pacer.launch.plist"
        if on {
            guard let exe = Bundle.main.executablePath else { return }
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key><string>com.dooly.pacer.launch</string>
              <key>ProgramArguments</key><array><string>\(exe)</string></array>
              <key>RunAtLoad</key><true/>
            </dict>
            </plist>
            """
            let dir = NSHomeDirectory() + "/Library/LaunchAgents"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? plist.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Misc

    /// 핑 방식 설명 — 모드별 트레이드오프 (Cloud 는 Pace log 가 근사).
    private var methodFooter: String {
        mode == "cloud"
            ? tr(lang,
                 "Claude Routine pings from the cloud — your Mac can stay off. Pace log is approximate (inferred from usage resets, not exact).",
                 "Claude Routine 이 클라우드에서 핑을 보냅니다 — 맥북이 꺼져 있어도 됩니다. Pace log 는 사용량 리셋으로 추론한 근사치라 정확하지 않습니다.")
            : tr(lang,
                 "launchd pings locally — exact Pace log, but your Mac must stay on.",
                 "launchd 가 로컬에서 핑을 보냅니다 — Pace log 는 정확하지만 맥북이 켜져 있어야 합니다.")
    }

    private func resetDefaults() {
        let d = Config.defaults
        hours = d.pingTimes.map { Int($0.split(separator: ":").first ?? "0") ?? 0 }
        skipWeekends = d.skipWeekends
        skipHolidays = d.skipHolidays
        save(mode: initialMode)
    }

    /// config 저장 + launchd 처리. mode 는 명시적으로 받는다 (Done 전엔 initialMode 로 저장 — 임시 모드 전환이 X 닫기에 새지 않게).
    private func save(mode m: String) {
        let times = hours.sorted().map { String(format: "%02d:00", $0) }
        let cfg = Config(pingTimes: times, skipWeekends: skipWeekends, skipHolidays: skipHolidays, pingMode: m)
        cfg.save()
        if m == "cloud" {
            PingScheduler.uninstall()
        } else {
            PingScheduler.reinstall(cfg)
        }
    }
}

/// SwiftUI 뷰에서 자신의 NSWindow 에 접근 (최상위 고정 등).
/// configure 는 창에 처음 붙을 때 1회만 — updateNSView 의 반복 호출이 닫힌 창을 다시 띄우는 것 방지.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = WAView()
        v.onWindow = configure
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {}
}

private final class WAView: NSView {
    var onWindow: ((NSWindow) -> Void)?
    private var done = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let w = window, !done { done = true; onWindow?(w) }
    }
}
