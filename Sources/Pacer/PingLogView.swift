import SwiftUI

/// 핑 발사 이력 한 줄.
struct PingEntry: Identifiable {
    let id = UUID()
    let date: String
    let slot: String
    let status: String
    let firedAt: String
}

extension PingLog {
    /// pings.jsonl → 최신순 엔트리.
    static func entries() -> [PingEntry] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: [PingEntry] = []
        for line in content.split(separator: "\n") {
            guard
                let data = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let date = obj["date"] as? String,
                let slot = obj["slot"] as? String,
                let status = obj["status"] as? String
            else { continue }
            out.append(PingEntry(date: date, slot: slot, status: status, firedAt: localTime(obj["ts"] as? String)))
        }
        return out.reversed() // 최신 먼저
    }

    /// ISO8601(UTC) → 로컬 "MM-dd HH:mm".
    private static func localTime(_ iso: String?) -> String {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
}

/// 핑 발사 상세 로그 창 (Date · Slot · Status · Fired at).
struct PingLogView: View {
    @State private var entries: [PingEntry] = PingLog.entries()
    @AppStorage("pacerLang") private var lang = "en"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr(lang, "Pace log", "페이스 로그")).font(.headline)
                Spacer()
                Text(tr(lang, "\(entries.count) pings", "\(entries.count)개")).font(.caption).foregroundStyle(.secondary)
                Button { entries = PingLog.entries() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            .padding(12)

            Table(entries) {
                TableColumn(tr(lang, "Date", "날짜")) { Text($0.date).monospacedDigit() }
                TableColumn(tr(lang, "Slot", "슬롯")) { Text($0.slot).monospacedDigit() }
                TableColumn(tr(lang, "Status", "상태")) { e in
                    Text(statusText(e.status))
                        .foregroundStyle(statusColor(e.status))
                }
                TableColumn(tr(lang, "Fired at", "발송 시각")) { Text($0.firedAt).monospacedDigit().foregroundStyle(.secondary) }
            }
        }
        .frame(minWidth: 460, minHeight: 380)
    }

    /// 상태 라벨 — sent/failed/missed 한글화.
    private func statusText(_ s: String) -> String {
        switch s {
        case "sent": return tr(lang, "Sent", "발송")
        case "auto": return tr(lang, "Auto", "자동")
        case "failed": return tr(lang, "Failed", "실패")
        case "missed": return tr(lang, "Missed", "누락")
        default: return s.capitalized
        }
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "sent": return .pacerPurple
        case "auto": return .pacerPurple.opacity(0.65)
        case "failed": return .pacerRed
        default: return .secondary
        }
    }
}
