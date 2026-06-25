import AppKit
import SwiftUI

/// 커스텀 About 창 — Pacer 다크 톤(보라 액센트). NSAlert 대체.
struct AboutView: View {
    var onCheckUpdate: () -> Void = {}
    var onGitHub: () -> Void = {}
    var onClose: () -> Void = {}
    var lang: String = "en"
    var version: String = ""

    var body: some View {
        VStack(spacing: 14) {
            // 앱 아이콘 + 타이틀 — 가운데 정렬
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Pacer \(version)")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)

            Divider()

            // 본문 — 왼쪽 정렬 블록
            VStack(alignment: .leading, spacing: 6) {
                Text(tr(lang,
                        "Paces your Claude usage from the menu bar.",
                        "메뉴바에서 Claude 사용량 페이스를 잡아줍니다."))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                Text("© 2026 codedooly · " + tr(lang, "MIT License", "MIT 라이선스"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 업데이트 확인 — 프라이머리(보라)
            Button(tr(lang, "Check for updates", "업데이트 확인")) { onCheckUpdate() }
                .buttonStyle(PacerButtonStyle(primary: true))

            HStack(spacing: 8) {
                Button("GitHub") { onGitHub() }
                    .buttonStyle(PacerButtonStyle(primary: false))
                Button(tr(lang, "Close", "닫기")) { onClose() }
                    .buttonStyle(PacerButtonStyle(primary: false))
            }
        }
        .padding()
        .frame(width: 320)
        .background(Color(red: 0.11, green: 0.11, blue: 0.125))
    }
}
