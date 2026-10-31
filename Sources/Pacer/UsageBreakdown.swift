import SwiftUI

/// 주간 사용량 소스 분해 — 세션 없음 모드(Ultra) 의 Usage 탭. 5h 슬롯 히트맵 대신
/// 이번 주 사용량이 어디서(Claude Code / Chats / Cowork / Other) 나왔는지 가로 막대로 보여준다.
struct UsageBreakdown: View {
    let rows: [BreakdownRow]        // API seven_day_breakdown.rows — 비중(%) 합 ≈ 100
    let weekly: UsageWindow?        // 주간 전체 한도(사용 % + 리셋) — 헤더 요약용
    let accent: Color               // 7-Day 도넛과 같은 정체성 색

    @AppStorage("pacerLang") private var lang = "en"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 헤더 — 이번 주 전체 사용률 + 리셋 카운트다운
            HStack(spacing: 6) {
                Text(tr(lang, "This week", "이번 주"))
                    .font(.system(size: 12, weight: .semibold))
                Text("\(weekly?.pct ?? 0)%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                Spacer()
                if let r = weekly?.resetsAt {
                    Label(MenuContent.remaining(r, lang), systemImage: "clock")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            // 소스별 막대 — 비중 0 인 행도 표시 (어떤 소스가 집계되는지 보이게)
            if rows.isEmpty {
                Text(tr(lang, "No weekly breakdown yet", "주간 분해 데이터 없음"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    bar(row)
                }
            }

            // 범례 — 비중의 의미 (주간 한도 소모량 중 소스 비중, 한도 대비 % 아님)
            Text(tr(lang, "Share of this week's usage by source — no 5-hour session on this plan",
                        "이번 주 사용량의 소스별 비중 — 이 플랜은 5시간 세션 없음"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(.top, 2)
    }

    /// 한 소스 행 — 이름(좌) · %(우) + 아래 비중 막대
    private func bar(_ row: BreakdownRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.name).font(.system(size: 11))
                Spacer()
                Text("\(row.pct)%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(row.pct > 0 ? Color.primary : Color.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule()
                        .fill(accent.opacity(row.pct > 0 ? 0.9 : 0))
                        .frame(width: max(0, geo.size.width * CGFloat(min(row.pct, 100)) / 100))
                }
            }
            .frame(height: 6)
        }
    }
}
