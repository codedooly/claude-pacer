import AppKit
import SwiftUI

enum PacerDialog {
    private static var windows: [NSWindow] = []   // 닫힐 때까지 유지
    /// Pacer 다크 다이얼로그 (NSAlert 대체). 버튼 클릭 시 completion(인덱스) 호출 후 닫힘.
    @MainActor
    static func show(title: String, message: String,
                     buttons: [(label: String, primary: Bool)],
                     icon: NSImage? = NSApp.applicationIconImage,
                     completion: ((Int) -> Void)? = nil) {
        // 다이얼로그 생성 전에 현재 키 윈도우(설정 등) 기억 — 그 중앙에 띄우기 위함
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { window.standardWindowButton($0)?.isHidden = true }
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .modalPanel   // 설정·닥터 등 일반 창 위에 확실히 (floating 으론 닥터 뒤로 숨던 문제)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]   // 현재 데스크탑 따라옴
        var done = false
        let finish: (Int) -> Void = { idx in
            guard !done else { return }; done = true
            window.orderOut(nil)
            windows.removeAll { $0 === window }
            completion?(idx)
        }
        let view = PacerDialogView(title: title, message: message, icon: icon, buttons: buttons, onClick: finish)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        // SwiftUI 콘텐츠 최종 크기로 윈도우를 맞춘 뒤 위치 계산 (center 가 초기 작은 rect 로 잡혀 모서리로 쏠리던 문제)
        host.view.layoutSubtreeIfNeeded()
        window.setContentSize(host.view.fittingSize)
        // 현재 데스크탑 중앙 — 부모(설정·닥터)가 있으면 그 화면, 없으면 마우스가 있는 화면 기준
        let anchorScreen = parent?.screen
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let vis = anchorScreen?.visibleFrame {
            let wf = window.frame
            // 중앙 상단 — 가로 중앙, 세로는 70% 지점(정중앙보다 위)
            window.setFrameOrigin(NSPoint(x: vis.midX - wf.width / 2,
                                          y: vis.minY + vis.height * 0.70 - wf.height / 2))
        } else {
            window.center()
        }
        windows.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()   // 닥터·설정 위로 확실히 (뒤로 숨던 문제 fix)
    }
}

struct PacerDialogView: View {
    let title: String; let message: String; let icon: NSImage?
    let buttons: [(label: String, primary: Bool)]; let onClick: (Int) -> Void
    var body: some View {
        VStack(spacing: 14) {
            if let icon { Image(nsImage: icon).resizable().frame(width: 56, height: 56) }
            Text(title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { i, b in
                    Button(b.label) { onClick(i) }.buttonStyle(PacerButtonStyle(primary: b.primary))
                }
            }
        }.padding(20).frame(width: 300).background(Color(white: 0.10))
    }
}

/// Pacer 버튼 — 1차=보라 채움, 2차=어두운 회색. 둥근 사각 통일.
struct PacerButtonStyle: ButtonStyle {
    var primary: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .background(primary ? Color.pacerPurple : Color(white: 0.20))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
