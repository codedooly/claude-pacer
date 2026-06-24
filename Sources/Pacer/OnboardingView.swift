import SwiftUI

/// Claude Code 미인증(토큰 없음) 시 메인 카드 대신 표시하는 온보딩.
/// 토큰이 감지되면 UsageModel.authed 가 true 가 되어 자동으로 메인으로 전환된다.
struct OnboardingView: View {
    @AppStorage("pacerLang") private var lang = "en"
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // 브랜드 워드마크(좌) + 언어 토글(우)
            HStack {
                Image("Wordmark").resizable().scaledToFit().frame(height: 24)
                Spacer()
                langToggle
            }

            // 헤드라인 + 설명
            VStack(spacing: 9) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.pacerPurple)
                    .padding(.top, 6)
                Text(tr(lang, "Connect Claude Code", "Claude Code 연결"))
                    .font(.system(size: 15, weight: .semibold))
                Text(tr(lang,
                        "Pacer reads your usage from Claude Code. Install it and log in once — your token stays in the macOS Keychain.",
                        "Pacer 는 Claude Code 에서 사용량을 읽어옵니다. 설치 후 한 번만 로그인하세요 — 토큰은 macOS Keychain 에만 보관됩니다."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 단계
            VStack(alignment: .leading, spacing: 11) {
                step(1, tr(lang, "Install Claude Code", "Claude Code 설치"))
                stepCmd(2, tr(lang, "Run", "터미널에서"), "claude", tr(lang, "and log in", "실행 후 로그인"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)

            // 설치 가이드 링크
            Link(destination: URL(string: "https://claude.com/claude-code")!) {
                HStack(spacing: 4) {
                    Text(tr(lang, "Install guide", "설치 가이드"))
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.pacerPurple)
            }
            .buttonStyle(.plain)

            // 재시도 (토큰 재확인) + 종료
            Button(action: onRetry) {
                Text(tr(lang, "I've logged in — Retry", "로그인했어요 — 다시 시도"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.pacerPurple)

            Button(tr(lang, "Quit", "종료")) { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// 언어 토글 — 워드마크 줄 우측 (EN / 한). 온보딩은 Settings 못 가니 여기서 전환.
    private var langToggle: some View {
        HStack(spacing: 2) {
            langButton("EN", "en")
            langButton("한국어", "ko")
        }
    }

    private func langButton(_ label: String, _ code: String) -> some View {
        Button { lang = code } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(lang == code ? .white : .secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(lang == code ? Color.pacerPurple : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 번호 배지 + 텍스트 단계.
    private func step(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 9) {
            numBadge(n)
            Text(text).font(.system(size: 12.5))
            Spacer()
        }
    }

    /// 번호 배지 + (앞말 · 모노스페이스 명령 · 뒷말) 단계.
    private func stepCmd(_ n: Int, _ pre: String, _ cmd: String, _ post: String) -> some View {
        HStack(spacing: 9) {
            numBadge(n)
            HStack(spacing: 5) {
                Text(pre).font(.system(size: 12.5))
                Text(cmd)
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                Text(post).font(.system(size: 12.5))
            }
            Spacer()
        }
    }

    private func numBadge(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 19, height: 19)
            .background(Circle().fill(Color.pacerPurple))
    }
}
