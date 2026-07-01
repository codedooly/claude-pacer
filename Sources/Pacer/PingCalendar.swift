import SwiftUI

/// 이번 달 블립 이력 캘린더 (render.py 의 캘린더 포팅).
/// 셀당 ping_times 개수만큼 점을 찍고, 로그 상태에 따라 색을 입힌다.
struct PingCalendar: View {
    let pingTimes: [String]
    let pings: [String: String] // "yyyy-MM-dd|HH:mm" -> "sent"/"failed"
    let holidays: Set<Date>     // skip_holidays 시 표시할 공휴일 (startOfDay). Cloud 모드면 빈 셋(매일 발사)
    let skipWeekends: Bool      // Local 모드에서 주말 스킵 시에만 true. Cloud 는 매일 발사라 false
    var monthOffset: Int = 0    // 표시 월 (0=이번 달, -1=지난 달 …). 상태/판정은 실제 today 기준

    @AppStorage("pacerLang") private var lang = "en"
    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)

    private var weekdayNames: [String] {
        lang == "ko" ? ["일", "월", "화", "수", "목", "금", "토"] : ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    }

    var body: some View {
        let today = Date()
        let displayMonth = cal.date(byAdding: .month, value: monthOffset, to: today) ?? today
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: displayMonth))!
        let dayCount = cal.range(of: .day, in: .month, for: displayMonth)!.count
        let leading = cal.component(.weekday, from: monthStart) - 1 // 1=Sun
        // 빈칸(leading) + 날짜를 하나의 [Int?] 배열로 — LazyVGrid 에서 빈칸 ForEach 와 날짜 ForEach 를 분리하면
        // 셀 배치가 어긋나(1~6일 누락) 므로 단일 ForEach 로 그린다. nil = 앞 빈칸.
        let slots: [Int?] = Array(repeating: nil, count: leading) + (1...dayCount).map { $0 }

        VStack(spacing: 6) {
            LazyVGrid(columns: columns, spacing: 9) {
                ForEach(Array(weekdayNames.enumerated()), id: \.offset) { i, nm in
                    Text(nm).font(.system(size: 10.5))
                        .foregroundStyle(i == 0 ? Color.pacerSunday.opacity(0.85) : i == 6 ? Color.pacerSaturday.opacity(0.85) : Color.secondary)
                }
                ForEach(Array(slots.enumerated()), id: \.offset) { _, day in
                    if let day {
                        cell(day: day, monthStart: monthStart, today: today)
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
            }

            legend
        }
    }

    @ViewBuilder
    private func cell(day: Int, monthStart: Date, today: Date) -> some View {
        let date = cal.date(byAdding: .day, value: day - 1, to: monthStart)!
        let isHoliday = holidays.contains(cal.startOfDay(for: date))
        // 스킵 적용일 = Local+주말스킵 주말 또는 (Local) 공휴일. Cloud 면 skipWeekends=false·holidays=[] 라 항상 false.
        let skipApplies = (skipWeekends && cal.isDateInWeekend(date)) || isHoliday
        let logged = loggedSlots(date)
        // 실제 찍힌 핑이 있으면(모드 전환 등) 스킵일이어도 진짜 점 표시. 스킵일+무로그만 off 처리.
        let isOff = skipApplies && logged.isEmpty
        // 점 슬롯: 스킵 적용일이면 실제 로그된 것만, 아니면 설정 슬롯 ∪ 로그
        let slots = skipApplies ? logged.sorted() : Array(Set(pingTimes).union(logged)).sorted()
        let isToday = cal.isDate(date, inSameDayAs: today)
        let isFuture = date > today && !isToday
        let dim = isOff || isFuture

        VStack(spacing: 5) {
            // 오늘 = 보라 원 안 흰 숫자 (월 넘겨도 '오늘 위치'가 보여 기록 사라진 게 아님을 인지)
            Text("\(day)")
                .font(.system(size: 14, weight: isToday ? .semibold : .regular))
                .foregroundStyle(isToday ? .white : Self.dayColor(weekday: cal.component(.weekday, from: date), dim: dim, holiday: isHoliday))
                .frame(width: 22, height: 22)
                .background(isToday ? Color.pacerPurple : Color.clear, in: Circle())
            HStack(spacing: 4.5) {
                if isOff {
                    Circle().fill(Color(white: 0.30)).frame(width: 4.5, height: 4.5)
                } else {
                    ForEach(slots, id: \.self) { slot in
                        dot(status: status(date: date, slot: slot, today: today))
                    }
                }
            }
            .frame(height: 10)
        }
        .frame(maxWidth: .infinity, minHeight: 32)
    }

    @ViewBuilder
    private func dot(status: String) -> some View {
        switch status {
        case "sent": Circle().fill(Color.pacerPurple).frame(width: 5.5, height: 5.5)
        case "auto": Circle().stroke(Color.pacerPurple, lineWidth: 1.3).frame(width: 5.5, height: 5.5) // 역산 추정 = 테두리만
        case "failed":
            Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(Color.pacerRed)
        case "missed": Circle().fill(Color(white: 0.47)).frame(width: 5.5, height: 5.5)
        default: Circle().fill(Color(white: 0.22)).frame(width: 5.5, height: 5.5) // pending
        }
    }

    /// 그날 실제 로그된 슬롯 목록 (정렬 전). 설정을 바꿔도 과거 핑은 로그 기반이라 보존.
    private func loggedSlots(_ date: Date) -> [String] {
        let prefix = "\(Self.dateStr(date))|"
        return pings.keys.compactMap { key in
            key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
        }
    }

    private func status(date: Date, slot: String, today: Date) -> String {
        let key = "\(Self.dateStr(date))|\(slot)"
        if let s = pings[key] { return s } // sent / failed
        let sameDay = cal.isDate(date, inSameDayAs: today)
        if date > today && !sameDay { return "pending" }
        if sameDay && slot > Self.nowHM() { return "pending" }
        return "missed"
    }

    private var legend: some View {
        HStack(spacing: 8) {
            legendItem(Color.pacerPurple, tr(lang, "Sent", "발송"))
            // auto = 테두리 원 (역산 추정)
            HStack(spacing: 3) {
                Circle().stroke(Color.pacerPurple, lineWidth: 1.2).frame(width: 7, height: 7)
                Text(tr(lang, "Auto", "자동"))
            }
            legendItem(Color.pacerRed, tr(lang, "Failed", "실패"))
            legendItem(Color(white: 0.47), tr(lang, "Missed", "누락"))
            legendItem(Color(white: 0.22), tr(lang, "Pending", "예정"))
            Spacer()
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.top, 6)
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }

    /// 날짜 숫자 색 — 주말(일 빨강/토 파랑) 우선, 평일은 흰/흐림.
    static func dayColor(weekday: Int, dim: Bool, holiday: Bool = false) -> Color {
        if holiday { return dim ? Color.pacerSunday.opacity(0.55) : .pacerSunday } // 공휴일 = 빨간날
        if let wc = Color.weekend(weekday) { return dim ? wc.opacity(0.55) : wc }
        return dim ? Color(white: 0.42) : Color(white: 0.93)
    }

    static func dateStr(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func nowHM() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }
}

/// pings.jsonl 로더 (menubar.5m.py 의 load_pings 포팅).
enum PingLog {
    static var path: String { NSHomeDirectory() + "/.config/claude-pacer/pings.jsonl" }

    static func load() -> [String: String] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in content.split(separator: "\n") {
            guard
                let data = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let date = obj["date"] as? String,
                let slot = obj["slot"] as? String,
                let status = obj["status"] as? String
            else { continue }
            out["\(date)|\(slot)"] = status
        }
        return out
    }

    /// usage 역산으로 추정한 핑 1건 기록 (같은 date|slot 이미 있으면 무시 — 확정 핑 우선).
    static func appendIfAbsent(date: String, slot: String, status: String, ts: Date) {
        if load()["\(date)|\(slot)"] != nil { return }
        let iso = ISO8601DateFormatter().string(from: ts)
        let line = "{\"date\":\"\(date)\",\"slot\":\"\(slot)\",\"status\":\"\(status)\",\"ts\":\"\(iso)\"}\n"
        let dir = NSHomeDirectory() + "/.config/claude-pacer"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let h = FileHandle(forWritingAtPath: path) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            if let d = line.data(using: .utf8) { h.write(d) }
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
