import SwiftUI

extension Color {
    static let pacerPurple = Color(red: 178 / 255, green: 90 / 255, blue: 240 / 255)
    static let pacerOrange = Color(red: 1, green: 159 / 255, blue: 10 / 255)
    static let claudeOrange = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255) // Claude 테마 주황(#D97757)
    static let pacerRed = Color(red: 1, green: 69 / 255, blue: 58 / 255)
    static let pacerTrack = Color(red: 46 / 255, green: 46 / 255, blue: 52 / 255)
    static let pacerSunday = Color(red: 1.0, green: 0.46, blue: 0.46)
    static let pacerSaturday = Color(red: 0.39, green: 0.78, blue: 0.98)

    /// 주말 색 (일=빨강, 토=파랑). 평일이면 nil.
    static func weekend(_ weekday: Int) -> Color? {
        if weekday == 1 { return .pacerSunday } // Sun
        if weekday == 7 { return .pacerSaturday } // Sat
        return nil
    }

    /// 사용률 임계 색: 보라 → 주황(60%) → 빨강(80%).
    static func pacerThreshold(_ pct: Int) -> Color {
        if pct >= 80 { return .pacerRed }
        if pct >= 60 { return .pacerOrange }
        return .pacerPurple
    }
}

/// 도넛 게이지 한 칸 (render.py 의 donut 포팅).
struct DonutGauge: View {
    let pct: Int
    let label: String
    let sub: String
    var size: CGFloat = 96   // 링 지름 (게이지 2개=96, 3개+=축소). 링 두께·숫자 폰트는 이에 비례
    var accent: Color? = nil // 라벨 옆 구분 점(게이지 정체성). 채움색은 임계값 유지

    private var clamped: CGFloat { CGFloat(min(max(pct, 0), 100)) / 100 }
    private var line: CGFloat { size / 9.6 }       // 96 → 10
    private var pctFont: CGFloat { size * 0.26 }    // 96 → 25

    var body: some View {
        VStack(spacing: 14) {
            // 라벨(도넛 위) + 정체성 점 (있을 때만)
            HStack(spacing: 5) {
                if let accent { Circle().fill(accent).frame(width: 6, height: 6) }
                Text(label).font(.system(size: 14, weight: .semibold))
            }
            ZStack {
                Circle()
                    .stroke(Color.pacerTrack, lineWidth: line)
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(Color.pacerThreshold(pct), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(pct)").font(.system(size: pctFont, weight: .semibold))
                    Text("%").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            // 리셋까지 남은 시간 — 도넛 아래 단독 (시계 아이콘으로 시선 유도)
            HStack(spacing: 3) {
                Image(systemName: "clock")
                Text(sub)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }
}
