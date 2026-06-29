import SwiftUI

/// Claude Code 미인증(토큰 없음) 시 메인 카드 대신 표시하는 온보딩.
/// 토큰이 감지되면 UsageModel.authed 가 true 가 되어 자동으로 메인으로 전환된다.
struct OnboardingView: View {
    @AppStorage("pacerLang") private var lang = "en"
    var isLoggingIn: Bool = false      // claude auth login 진행 중 (스피너)
    var loginURL: URL? = nil           // claude 가 출력한 OAuth URL (자동 안 열릴 때 클릭용)
    var onLogin: () -> Void            // 주 동작 — 브라우저 OAuth 로그인
    var onCancel: () -> Void = {}      // 로그인 취소 (스피너 해제)
    var onRetry: () -> Void
    @State private var showFallback = false   // "안 되면" 터미널 직접 방법 펼침

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
                Text(tr(lang, "Sign in to Claude", "Claude 로그인"))
                    .font(.system(size: 15, weight: .semibold))
                Text(tr(lang,
                        "Sign in once and Pacer reads your usage from Claude Code — your token stays in the macOS Keychain.",
                        "한 번 로그인하면 Pacer 가 Claude Code 에서 사용량을 읽어옵니다 — 토큰은 macOS Keychain 에만 보관됩니다."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 주 동작 — 브라우저 로그인 (claude auth login)
            Button(action: onLogin) {
                HStack(spacing: 6) {
                    if isLoggingIn { ProgressView().controlSize(.small) }
                    Text(isLoggingIn
                         ? tr(lang, "Waiting for browser…", "브라우저 로그인 대기 중…")
                         : tr(lang, "Sign in to Claude", "Claude 로그인"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.pacerPurple)
            .controlSize(.large)
            .disabled(isLoggingIn)

            // 로그인 중 — URL 직접 열기 링크(자동 안 열릴 때) + 취소
            if isLoggingIn {
                VStack(spacing: 7) {
                    if let loginURL {
                        Link(destination: loginURL) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.forward.app")
                                Text(tr(lang, "Browser didn't open? Open login", "브라우저가 안 열렸나요? 여기로 로그인"))
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.pacerPurple)
                        }
                        .buttonStyle(.plain)
                    }
                    Button(tr(lang, "Cancel", "취소"), action: onCancel)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            // fallback — "안 되면" 터미널 직접 방법 (접힘)
            VStack(spacing: 10) {
                Button(action: { withAnimation { showFallback.toggle() } }) {
                    HStack(spacing: 3) {
                        Text(tr(lang, "Not working?", "안 되나요?"))
                        Image(systemName: showFallback ? "chevron.up" : "chevron.down").font(.system(size: 9))
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if showFallback {
                    VStack(alignment: .leading, spacing: 11) {
                        step(1, tr(lang, "Install Claude Code", "Claude Code 설치"))
                        stepCmd(2, tr(lang, "Run", "터미널에서"), "claude", tr(lang, "and log in", "실행 후 로그인"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        Link(destination: URL(string: "https://claude.com/claude-code")!) {
                            HStack(spacing: 4) {
                                Text(tr(lang, "Install guide", "설치 가이드"))
                                Image(systemName: "arrow.up.right")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.pacerPurple)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button(tr(lang, "I've logged in — Retry", "로그인했어요 — 다시 시도"), action: onRetry)
                            .font(.system(size: 11))
                    }
                }
            }

            Button(tr(lang, "Quit", "종료")) { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// 언어 토글 — 워드마크 줄 우측 (EN / 한). 온보딩은 Settings 못 가니 여기서 전환.
    private var langToggle: some View {
        HStack(spacing: 2) {
            langButton("English", "en")
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
