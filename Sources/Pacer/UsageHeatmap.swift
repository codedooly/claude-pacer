import SwiftUI

/// 일별 사용량 — 하루 3개 5시간 창(오전·오후·야간) 각각의 피크를 셀 안 미니 3바로.
struct UsageHeatmap: View {
    let history: [String: [String: Int]] // "yyyy-MM-dd" -> { slot: peak% }
    let pingTimes: [String]

    @AppStorage("pacerLang") private var lang = "en"
    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)

    private var weekdayNames: [String] {
        lang == "ko" ? ["일", "월", "화", "수", "목", "금", "토"] : ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    }

    var body: some View {
        let today = Date()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: today))!
        let dayCount = cal.range(of: .day, in: .month, for: today)!.count
        let leading = cal.component(.weekday, from: monthStart) - 1

        VStack(spacing: 6) {
            LazyVGrid(columns: columns, spacing: 9) {
                ForEach(Array(weekdayNames.enumerated()), id: \.offset) { i, nm in
                    Text(nm).font(.system(size: 10.5))
                        .foregroundStyle(i == 0 ? Color.pacerSunday.opacity(0.85) : i == 6 ? Color.pacerSaturday.opacity(0.85) : Color.secondary)
                }
                ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: 1) }
                ForEach(1...dayCount, id: \.self) { day in
                    cell(day: day, monthStart: monthStart, today: today)
                }
            }

            legend
        }
    }

    @ViewBuilder
    private func cell(day: Int, monthStart: Date, today: Date) -> some View {
        let date = cal.date(byAdding: .day, value: day - 1, to: monthStart)!
        let future = date > today && !cal.isDate(date, inSameDayAs: today)
        let slots = history[PingCalendar.dateStr(date)] ?? [:]
        // 그날 기록된 슬롯 ∪ 현재 핑 — 과거(핑 개수 다르던 시절) 데이터도 빠짐없이 표시
        let allSlots = Array(Set(pingTimes).union(slots.keys)).sorted()

        VStack(spacing: 5) {
            Text("\(day)")
                .font(.system(size: 14))
                .foregroundStyle(dayColor(weekday: cal.component(.weekday, from: date), future: future))
            HStack(spacing: 2) {
                ForEach(allSlots, id: \.self) { slot in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(barColor(pct: slots[slot] ?? 0, future: future))
                        .frame(maxWidth: .infinity)
                        .frame(height: 8)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32)
    }

    private func barColor(pct: Int, future: Bool) -> Color {
        if future { return Color(white: 0.10) }
        if pct <= 0 { return Color(white: 0.16) }
        // 낮음~높음 농도 (베이스·범위 올려 더 짙게)
        return Color.pacerPurple.opacity(0.32 + Double(min(pct, 100)) / 100 * 0.68)
    }

    /// 날짜 색 — 주말(일 빨강/토 파랑), 미래는 흐림. (Usage 는 주말도 활성)
    private func dayColor(weekday: Int, future: Bool) -> Color {
        if let wc = Color.weekend(weekday) { return future ? wc.opacity(0.45) : wc }
        return future ? Color(white: 0.40) : Color(white: 0.90)
    }

    private var legend: some View {
        HStack(spacing: 6) {
            ForEach(pingTimes, id: \.self) { slot in
                Text(Self.slotLabel(slot, lang)).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(tr(lang, "low", "낮음")).font(.system(size: 10.5)).foregroundStyle(.secondary)
            ForEach([0.3, 0.6, 0.95], id: \.self) { o in
                RoundedRectangle(cornerRadius: 1.5).fill(Color.pacerPurple.opacity(o)).frame(width: 12, height: 8)
            }
            Text(tr(lang, "full", "높음")).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    /// 슬롯 라벨 — 핑 시각의 시 (히트맵 막대가 핑 창과 1:1 매칭).
    static func slotLabel(_ s: String, _ lang: String) -> String {
        let h = Int(s.split(separator: ":").first ?? "0") ?? 0
        return lang == "ko" ? "\(h)시" : "\(h)h"
    }
}

/// 일별 · 창별 5시간 피크 사용량 저장소.  { date: { slot: peak% } }
enum UsageHistory {
    static var dir: String { NSHomeDirectory() + "/.config/claude-pacer" }
    static var path: String { dir + "/usage_history.json" }

    static func load() -> [String: [String: Int]] {
        guard
            let data = FileManager.default.contents(atPath: path),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: [String: Int]] = [:]
        for (date, value) in obj {
            guard let slots = value as? [String: Any] else { continue } // 옛 포맷({date:int})은 무시
            var day: [String: Int] = [:]
            for (slot, p) in slots { if let n = p as? NSNumber { day[slot] = n.intValue } }
            out[date] = day
        }
        return out
    }

    /// 현재 5h util 을 (resets_at 으로 식별한) 창 슬롯에 max 누적.
    static func record(pct: Int, resetsAt: Date?, pingTimes: [String]) {
        guard let resetsAt else { return }
        let slot = slotName(for: resetsAt, pingTimes: pingTimes)
        // 창 시작 날짜에 기록 (자정 넘는 창도 정확 — '오늘'이 아니라 창 시작 기준)
        let dateStr = PingCalendar.dateStr(resetsAt.addingTimeInterval(-5 * 3600))
        var hist = load()
        var day = hist[dateStr] ?? [:]
        day[slot] = max(day[slot] ?? 0, pct)
        hist[dateStr] = day
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: hist) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// resets_at − 5h = 창 시작 → 가장 가까운 핑 슬롯.
    static func slotName(for resetsAt: Date, pingTimes: [String]) -> String {
        let start = resetsAt.addingTimeInterval(-5 * 3600)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let startMin = minutes(f.string(from: start))
        return pingTimes.min { abs(minutes($0) - startMin) < abs(minutes($1) - startMin) }
            ?? (pingTimes.first ?? "08:00")
    }

    private static func minutes(_ hm: String) -> Int {
        let p = hm.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return 0 }
        return h * 60 + m
    }
}
