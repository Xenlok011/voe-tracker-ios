import SwiftUI
import UserNotifications
import WebKit
import UIKit

struct HourSlot: Identifiable, Codable, Equatable {
    var id: String { "\(hour)-\(detail)" }
    let hour: String
    let hasDisconnection: Bool
    let detail: String
}

struct DaySchedule: Identifiable, Codable, Equatable {
    var id: String { label }
    let label: String
    let hours: [HourSlot]
}

struct SchedulePayload: Codable, Equatable {
    let checkedAt: String
    let queue: String?
    let hasReserve: Bool
    let days: [DaySchedule]
}

enum VoeParser {
    static func parse(rawJSONString: String) throws -> SchedulePayload {
        guard let data = rawJSONString.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tables = root["tables"] as? [[String: Any]],
              let table = tables.first else {
            throw NSError(domain: "VoeParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не найден tables[0]"])
        }

        let queueStr: String? = {
            if let v = table["listnum"] { return "\(v)" }
            return nil
        }()
        let reserve = (table["reserve"] as? Bool) ?? false

        var days: [DaySchedule] = []
        let rows = (table["rows"] as? [[String: Any]]) ?? []

        for row in rows {
            let label = (row["label"] as? String) ?? (row["date"] as? String) ?? ""
            var hours: [HourSlot] = []
            let cells = (row["cells"] as? [[String: Any]]) ?? []

            for cell in cells {
                let hour = (cell["hour"] as? String) ?? ""
                let cssClass = (cell["class"] as? String) ?? ""
                let segs = (cell["segments"] as? [[String: Any]]) ?? []

                let hasDisc = !segs.isEmpty || (
                    cssClass.contains("has_disconnection") && !cssClass.contains("no_disconnection")
                )
                let detail = segs.compactMap { $0["label"] as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")

                hours.append(HourSlot(hour: hour, hasDisconnection: hasDisc, detail: detail))
            }

            days.append(DaySchedule(label: label, hours: hours))
        }

        let formatter = ISO8601DateFormatter()
        let nowStr = formatter.string(from: Date())

        return SchedulePayload(
            checkedAt: nowStr,
            queue: queueStr,
            hasReserve: reserve,
            days: days
        )
    }
}

enum NotificationManager {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func sendNow(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    static func scheduleUpcomingDisconnections(payload: SchedulePayload, leadMinutes: Int) {
        guard leadMinutes > 0 else { return }
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()

        let now = Date()
        let cal = Calendar.current
        let queueLabel = payload.queue.map { "Черга \($0)" } ?? "ВОЕ Трекер"

        for day in payload.days {
            guard let baseDate = parseDayBaseDate(label: day.label, now: now, cal: cal) else { continue }

            for slot in day.hours where slot.hasDisconnection {
                guard let (startHour, startMinute) = extractStartTime(hour: slot.hour, detail: slot.detail) else { continue }

                var comps = cal.dateComponents([.year, .month, .day], from: baseDate)
                comps.hour = startHour
                comps.minute = startMinute
                comps.second = 0

                guard var startDate = cal.date(from: comps) else { continue }
                if startDate.timeIntervalSince(now) < -12 * 3600 {
                    startDate = cal.date(byAdding: .day, value: 1, to: startDate) ?? startDate
                }

                let alertDate = startDate.addingTimeInterval(TimeInterval(-leadMinutes * 60))
                guard alertDate > now else { continue }

                let content = UNMutableNotificationContent()
                content.title = "Отключение через \(leadMinutes) мин"
                let hmFormatter = DateFormatter()
                hmFormatter.dateFormat = "HH:mm"
                let extra = slot.detail.isEmpty ? "" : " (\(slot.detail))"
                content.body = "\(queueLabel): отключение в \(hmFormatter.string(from: startDate)) [\(slot.hour)\(extra)]"
                content.sound = .default

                let triggerComps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: alertDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComps, repeats: false)
                let id = "voe_disc_\(startDate.timeIntervalSince1970)_\(slot.hour)"
                let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
                center.add(request)
            }
        }
    }

    private static func parseDayBaseDate(label: String, now: Date, cal: Calendar) -> Date? {
        let pattern = #"(\d{1,2})\.(\d{1,2})"#
        if let range = label.range(of: pattern, options: .regularExpression) {
            let match = String(label[range])
            let parts = match.split(separator: ".")
            if parts.count == 2, let day = Int(parts[0]), let month = Int(parts[1]) {
                var year = cal.component(.year, from: now)
                if cal.component(.month, from: now) == 12 && month == 1 {
                    year += 1
                }
                var comps = DateComponents()
                comps.year = year
                comps.month = month
                comps.day = day
                return cal.date(from: comps)
            }
        }
        return cal.startOfDay(for: now)
    }

    private static func extractStartTime(hour: String, detail: String) -> (Int, Int)? {
        for src in [detail, hour] {
            if let r = src.range(of: #"\b([01]?\d|2[0-3]):([0-5]\d)\b"#, options: .regularExpression) {
                let sub = String(src[r])
                let p = sub.split(separator: ":")
                if p.count == 2, let h = Int(p[0]), let m = Int(p[1]) {
                    return (h, m)
                }
            }
        }
        if let r = hour.range(of: #"\b([01]?\d|2[0-3])\s*[-–—]\s*([01]?\d|2[0-4])\b"#, options: .regularExpression) {
            let sub = String(hour[r])
            let p = sub.components(separatedBy: CharacterSet(charactersIn: "-–—"))
            if let first = p.first?.trimmingCharacters(in: .whitespaces), var h = Int(first) {
                if h == 24 { h = 0 }
                return (h, 0)
            }
        }
        return nil
    }
}

struct VoeWebSheet: View {
    let url: URL
    let onExtractedJSON: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var webView = WKWebView()
    @State private var extractError = ""

    private let extractScript = """
    (() => {
      const table = document.querySelector("table");
      if (!table) {
        return JSON.stringify({ error: "Таблица графика не найдена на странице" });
      }
      const trs = Array.from(table.querySelectorAll("tr"));
      if (trs.length < 2) {
        return JSON.stringify({ error: "В таблице недостаточно строк" });
      }
      const headerCells = Array.from(trs[0].querySelectorAll("th, td")).slice(1);
      const hours = headerCells.map(c => c.innerText.trim());

      const rows = trs.slice(1).map(tr => {
        const tds = Array.from(tr.querySelectorAll("th, td"));
        const label = (tds[0]?.innerText || "").trim();
        const cells = tds.slice(1).map((td, idx) => {
          const cls = td.className || "";
          const txt = td.innerText.trim();
          const hasDisc = cls.includes("has_disconnection") || (txt !== "" && !cls.includes("no_disconnection"));
          return {
            hour: hours[idx] || `${idx}-${idx + 1}`,
            class: hasDisc ? "has_disconnection" : "no_disconnection",
            segments: txt ? [{ label: txt }] : []
          };
        });
        return { label, cells };
      }).filter(r => r.label && r.cells.length > 0);

      const queueMatch = document.body.innerText.match(/Черга[:\\s]*([0-9.]+)/i);
      return JSON.stringify({
        tables: [{
          listnum: queueMatch ? queueMatch[1] : "—",
          reserve: false,
          rows: rows
        }]
      });
    })();
    """

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !extractError.isEmpty {
                    Text(extractError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.orange.opacity(0.12))
                }
                WebViewContainer(webView: webView, url: url)
            }
            .navigationTitle("Сайт ВОЕ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Забрать график") {
                        webView.evaluateJavaScript(extractScript) { result, error in
                            if let error = error {
                                extractError = "Ошибка скрипта: \(error.localizedDescription)"
                                return
                            }
                            guard let jsonStr = result as? String else {
                                extractError = "Не удалось получить данные со страницы"
                                return
                            }
                            if let data = jsonStr.data(using: .utf8),
                               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let errMsg = obj["error"] as? String {
                                extractError = errMsg
                                return
                            }
                            onExtractedJSON(jsonStr)
                            dismiss()
                        }
                    }
                    .bold()
                }
            }
        }
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ContentView: View {
    @AppStorage("voe_city") private var city = "м.Вінниця (Вінницька Область/М.Вінниця)"
    @AppStorage("voe_street") private var street = "вулиця Генерала Григоренка"
    @AppStorage("voe_house") private var house = "69"
    @AppStorage("voe_lead_min") private var leadMinutes = 10
    @AppStorage("voe_notify_changes") private var notifyChanges = true
    @AppStorage("voe_cached_json") private var cachedJson = ""

    @State private var payload: SchedulePayload?
    @State private var changedBanner = false
    @State private var showJsonSheet = false
    @State private var showWebSheet = false
    @State private var rawJsonInput = ""
    @State private var statusText = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 8) {
                        TextField("Город", text: $city)
                            .textFieldStyle(.roundedBorder)
                        HStack(spacing: 8) {
                            TextField("Улица", text: $street)
                                .textFieldStyle(.roundedBorder)
                            TextField("Дом", text: $house)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 76)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Уведомлять об изменениях", isOn: $notifyChanges)
                        Stepper("Напоминать за \(leadMinutes) мин", value: $leadMinutes, in: 0...120)
                            .onChange(of: leadMinutes) { _, _ in
                                if let p = payload {
                                    NotificationManager.scheduleUpcomingDisconnections(payload: p, leadMinutes: leadMinutes)
                                }
                            }
                    }
                    .font(.subheadline)
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(payload?.queue.map { "Черга \($0)" } ?? "Черга —")
                            .font(.title.bold())
                        if let checked = payload?.checkedAt {
                            Text("Обновлено: \(checked)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !statusText.isEmpty {
                            Text(statusText)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    if changedBanner {
                        Text("График или очередь обновились!")
                            .font(.footnote.bold())
                            .foregroundStyle(.green)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    if let days = payload?.days, !days.isEmpty {
                        ForEach(days) { day in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(day.label)
                                    .font(.headline)
                                LazyVGrid(columns: columns, spacing: 6) {
                                    ForEach(day.hours) { slot in
                                        VStack(spacing: 2) {
                                            Text(slot.hour)
                                                .font(.caption2.bold())
                                            Text(slot.hasDisconnection ? (slot.detail.isEmpty ? "Откл" : slot.detail) : "Свет")
                                                .font(.caption2)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .padding(.horizontal, 3)
                                        .background(slot.hasDisconnection ? Color.orange.opacity(0.22) : Color(.secondarySystemBackground))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(slot.hasDisconnection ? Color.orange : Color(.separator), lineWidth: 1)
                                        )
                                        .foregroundStyle(slot.hasDisconnection ? Color.orange : Color.primary)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                        }
                    } else {
                        Text("Нет данных графика. Нажмите «Обновить» или «Вставить JSON».")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(24)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding()
            }
            .navigationTitle("ВОЕ Трекер")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Обновить") {
                        showWebSheet = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("JSON") {
                        rawJsonInput = UIPasteboard.general.string ?? ""
                        showJsonSheet = true
                    }
                }
            }
            .sheet(isPresented: $showWebSheet) {
                VoeWebSheet(url: URL(string: "https://disconnection.voe.com.ua/")!) { extractedJson in
                    applyRawJson(extractedJson)
                }
            }
            .sheet(isPresented: $showJsonSheet) {
                NavigationStack {
                    VStack(spacing: 12) {
                        TextEditor(text: $rawJsonInput)
                            .font(.system(.caption, design: .monospaced))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator)))
                        Button("Применить и запланировать уведомления") {
                            applyRawJson(rawJsonInput)
                            showJsonSheet = false
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                    .padding()
                    .navigationTitle("JSON ответа")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Закрыть") { showJsonSheet = false }
                        }
                    }
                }
            }
            .onAppear {
                NotificationManager.requestPermission()
                loadCached()
            }
        }
    }

    private func loadCached() {
        guard !cachedJson.isEmpty,
              let data = cachedJson.data(using: .utf8),
              let saved = try? JSONDecoder().decode(SchedulePayload.self, from: data) else { return }
        payload = saved
        NotificationManager.scheduleUpcomingDisconnections(payload: saved, leadMinutes: leadMinutes)
    }

    private func applyRawJson(_ raw: String) {
        do {
            let parsed = try VoeParser.parse(rawJSONString: raw)
            let isChanged = (payload != nil) && (
                payload?.queue != parsed.queue ||
                payload?.hasReserve != parsed.hasReserve ||
                payload?.days != parsed.days
            )
            changedBanner = isChanged
            payload = parsed
            statusText = ""

            if let encoded = try? JSONEncoder().encode(parsed),
               let str = String(data: encoded, encoding: .utf8) {
                cachedJson = str
            }

            if isChanged && notifyChanges {
                let q = parsed.queue ?? "—"
                NotificationManager.sendNow(
                    title: "ВОЕ Трекер: график обновился",
                    body: "Изменился график или очередь (Черга \(q))."
                )
            }

            NotificationManager.scheduleUpcomingDisconnections(payload: parsed, leadMinutes: leadMinutes)
        } catch {
            statusText = "Ошибка JSON: \(error.localizedDescription)"
        }
    }
}
