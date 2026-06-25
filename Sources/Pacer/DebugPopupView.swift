#if PACER_DEBUG
import SwiftUI

/// 디버그 전용 — 각 다이얼로그를 더미로 띄워 디자인·언어를 확인하는 창 (릴리즈 빌드엔 미포함).
struct DebugPopupView: View {
    @AppStorage("pacerLang") private var lang = "en"
    let onAbout: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $lang) { Text("English").tag("en"); Text("한국어").tag("ko") }
                .pickerStyle(.segmented).labelsHidden()
            Divider()
            btn("About") { onAbout() }
            btn("업데이트 — 최신") {
                PacerDialog.show(title: "Pacer",
                    message: tr(lang, "You're on the latest version (1.1.8).", "최신 버전입니다 (1.1.8)."),
                    buttons: [(tr(lang,"OK","확인"), true)])
            }
            btn("업데이트 — 새 버전") {
                PacerDialog.show(title: tr(lang,"Update Pacer","Pacer 업데이트"),
                    message: tr(lang,"Current  1.1.8  →  Latest  1.1.9\n\nDownload and restart?","현재  1.1.8  →  최신  1.1.9\n\n받아서 재시작합니다. 계속할까요?"),
                    buttons: [(tr(lang,"Cancel","취소"), false), (tr(lang,"Update","업데이트"), true)])
            }
            btn("업데이트 — 확인 실패") {
                PacerDialog.show(title: "Pacer",
                    message: tr(lang,"Couldn't check for updates — check your connection.","업데이트 확인 실패 — 인터넷 연결을 확인하세요."),
                    buttons: [(tr(lang,"OK","확인"), true)])
            }
            btn("적용 성공") {
                PacerDialog.show(title: tr(lang,"Applied","적용 완료"),
                    message: tr(lang,"Cloud routine registered — pings fire daily at 08:00 · 13:00 · 18:00. Next: tomorrow 08:02.","Cloud routine 등록 완료 — 매일 08:00 · 13:00 · 18:00 발화. 다음: 내일 08:02."),
                    buttons: [(tr(lang,"OK","확인"), true)])
            }
            btn("Cloud 등록 실패") {
                PacerDialog.show(title: tr(lang,"Cloud registration failed","Cloud 등록 실패"),
                    message: "API Error: 404 {\"type\":\"not_found_error\",\"message\":\"...example...\"}",
                    buttons: [(tr(lang,"OK","확인"), true)])
            }
        }.padding(16).frame(width: 280)
    }
    @ViewBuilder private func btn(_ t: String, _ a: @escaping () -> Void) -> some View {
        Button(t, action: a).buttonStyle(PacerButtonStyle()).frame(maxWidth: .infinity)
    }
}
#endif
