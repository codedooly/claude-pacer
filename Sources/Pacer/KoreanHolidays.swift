import Foundation

/// 한국 공휴일 판정 — Foundation 만으로 (양력 고정 + 음력 계산, 외부 의존 0 · 매년 자동).
/// Note: 대체공휴일은 후속. 주말과 겹친 공휴일은 이미 주말 skip 으로 처리됨.
enum KoreanHolidays {
    /// 양력 고정 공휴일 (월-일).
    private static let fixed: Set<String> = [
        "1-1",   // 신정
        "3-1",   // 삼일절
        "5-5",   // 어린이날
        "6-6",   // 현충일
        "8-15",  // 광복절
        "10-3",  // 개천절
        "10-9",  // 한글날
        "12-25", // 성탄절
    ]

    /// 해당 양력 연도의 모든 공휴일 (양력 고정 + 음력) — 캘린더 표시용 (1회 계산).
    static func holidays(year: Int) -> Set<Date> {
        let greg = Calendar(identifier: .gregorian)
        var out = Set<Date>()
        for f in fixed {
            let p = f.split(separator: "-")
            if p.count == 2, let m = Int(p[0]), let d = Int(p[1]),
               let date = greg.date(from: DateComponents(year: year, month: m, day: d)) {
                out.insert(greg.startOfDay(for: date))
            }
        }
        for d in lunarHolidays(year: year) { out.insert(greg.startOfDay(for: d)) }
        return out
    }

    static func isHoliday(_ date: Date) -> Bool {
        let greg = Calendar(identifier: .gregorian)
        let c = greg.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return false }

        if fixed.contains("\(m)-\(d)") { return true }

        // 음력 공휴일 (설날±1, 추석±1, 석가탄신일)
        let today = greg.startOfDay(for: date)
        return lunarHolidays(year: y).contains { greg.isDate($0, inSameDayAs: today) }
    }

    private static func lunarHolidays(year: Int) -> [Date] {
        var out: [Date] = []
        if let seol = solarDate(lunarMonth: 1, lunarDay: 1, year: year) {
            out += around(seol, [-1, 0, 1]) // 설 연휴 3일
        }
        if let chuseok = solarDate(lunarMonth: 8, lunarDay: 15, year: year) {
            out += around(chuseok, [-1, 0, 1]) // 추석 연휴 3일
        }
        if let buddha = solarDate(lunarMonth: 4, lunarDay: 8, year: year) {
            out.append(buddha) // 석가탄신일
        }
        return out
    }

    private static func around(_ d: Date, _ offsets: [Int]) -> [Date] {
        let cal = Calendar(identifier: .gregorian)
        return offsets.compactMap { cal.date(byAdding: .day, value: $0, to: d) }
    }

    /// 음력(month/day) → 해당 양력 연도의 날짜 (Foundation chinese calendar).
    private static func solarDate(lunarMonth: Int, lunarDay: Int, year: Int) -> Date? {
        let greg = Calendar(identifier: .gregorian)
        let chinese = Calendar(identifier: .chinese)
        guard
            var date = greg.date(from: DateComponents(year: year, month: 1, day: 1)),
            let end = greg.date(from: DateComponents(year: year, month: 12, day: 31))
        else { return nil }
        while date <= end {
            let lc = chinese.dateComponents([.month, .day, .isLeapMonth], from: date)
            if lc.month == lunarMonth, lc.day == lunarDay, lc.isLeapMonth != true {
                return greg.startOfDay(for: date)
            }
            date = greg.date(byAdding: .day, value: 1, to: date)!
        }
        return nil
    }
}
