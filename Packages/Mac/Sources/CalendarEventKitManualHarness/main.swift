//  CalendarEventKitManualHarness
//
//  Модуль: calendar-eventkit · Владелец: DEV-1 · Слой: тестовое средство модуля (исполняемый таргет)
//
//  Каталог принадлежит владельцу модуля calendar-eventkit: файлы здесь изменяет только он (П1).
//  Назначение — перечень MEE-339, раздел «З», и план MEE-343, §5: интерактивный носитель
//  ручных М1/М2. Вызывает `EKEventStore` НАПРЯМУЮ, в обход calendar-eventkit — М1/М2 измеряют
//  факты о самом EventKit (граница «весь день», развёртка повторений, код ошибки при
//  отозванном праве), а не поведение модуля.
//
//  Два подрежима — один процесс:
//    m1   М1 (§5): печатает сырые факты EventKit по событиям в окне — `endDate` события
//         «весь день» (К13) и структуру вхождений повторяющегося события: `eventIdentifier`,
//         `occurrenceDate`, вычисленный `externalId` (та же форма, что `EventKitCoreGateway.
//         externalId(for:)`, продублирована здесь — носитель не импортирует calendar-eventkit,
//         это независимое измерение, не повторный вызов уже написанного кода) — калибрует К19.
//    m2   М2 (§5): печатает статус права `.calendars` до и после паузы для ручного отзыва,
//         затем вызывает `calendars(for:)`/`events(matching:)` и печатает исход — калибрует
//         развилку Р7.

import EventKit
import Foundation

// MARK: - Разбор аргументов (тот же приём, что CaptureManualHarness, MEE-316)

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

private struct Arguments {
    var values: [String: String] = [:]

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let token = raw[index]
            if token.hasPrefix("--"), index + 1 < raw.count {
                values[String(token.dropFirst(2))] = raw[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
    }

    subscript(_ key: String) -> String? { values[key] }
}

private let usage = """
CalendarEventKitManualHarness — носитель М1/М2 (план MEE-343 §5). Вызывает EKEventStore
НАПРЯМУЮ, в обход calendar-eventkit.

  m1 [--calendar TITLE] [--days-back 7] [--days-forward 14]
        М1: печатает сырые факты EventKit по всем событиям в окне — endDate события «весь
        день» и структуру вхождений повторяющегося события (eventIdentifier, occurrenceDate,
        externalId по форме коннектора). --calendar сужает поиск по заголовку календаря.

  m2 [--wait-seconds 20]
        М2: печатает статус права .calendars, ждёт --wait-seconds (успеть отозвать право в
        Системных настройках), затем вызывает calendars(for:)/events(matching:) и печатает
        исход — код/тип ошибки либо пустой результат, либо ничего (см. README.md).
"""

let rawArguments = Array(CommandLine.arguments.dropFirst())
guard let mode = rawArguments.first else { fail(usage) }
private let arguments = Arguments(Array(rawArguments.dropFirst()))
private let store = EKEventStore()

switch mode {
case "m1":
    await runM1(arguments)
case "m2":
    await runM2(arguments)
default:
    fail(usage)
}

// MARK: - Общее

private func requestAccess() async -> Bool {
    do {
        return try await store.requestFullAccessToEvents()
    } catch {
        print("requestFullAccessToEvents: throw \(error)")
        fflush(stdout)
        return false
    }
}

private func printStatus(_ label: String) {
    let status = EKEventStore.authorizationStatus(for: .event)
    print("\(label): authorizationStatus = \(status)")
    fflush(stdout)
}

/// Та же форма, что `EventKitCoreGateway.externalId(for:)` (Sources/CalendarEventKit,
/// `// СТРОКА:` там же) — М1 калибрует именно её.
private func externalId(for event: EKEvent) -> String {
    "\(event.eventIdentifier ?? ""):\(Int(event.occurrenceDate.timeIntervalSince1970))"
}

private let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

// MARK: - М1 — граница «весь день» и развёртка повторений

private func resolveCalendars(titled title: String?) -> [EKCalendar]? {
    guard let title else { return nil }
    let matched = store.calendars(for: .event).filter { $0.title == title }
    if matched.isEmpty {
        print("m1: календарь с заголовком \"\(title)\" не найден, ищу по всем")
        fflush(stdout)
        return nil
    }
    return matched
}

private func printEvent(_ event: EKEvent) {
    print("""
    m1: событие "\(event.title ?? "")" календарь="\(event.calendar.title)" \
    isAllDay=\(event.isAllDay) start=\(isoFormatter.string(from: event.startDate)) \
    end=\(isoFormatter.string(from: event.endDate)) \
    eventIdentifier=\(event.eventIdentifier ?? "nil") \
    occurrenceDate=\(isoFormatter.string(from: event.occurrenceDate)) \
    hasRecurrenceRules=\(event.hasRecurrenceRules) externalId=\(externalId(for: event))
    """)
    fflush(stdout)
}

private func printSummaryByTitle(_ events: [EKEvent]) {
    let byTitle = Dictionary(grouping: events, by: { $0.title ?? "" })
    print("m1: сводка по заголовку (для повторяющегося события ожидается >1 запись, разные externalId):")
    for (title, group) in byTitle.sorted(by: { $0.key < $1.key }) {
        let ids = group.map(externalId).joined(separator: ", ")
        print("m1:   \"\(title)\" — \(group.count) вхожд., externalId: [\(ids)]")
    }
    fflush(stdout)
}

private func runM1(_ arguments: Arguments) async {
    guard await requestAccess() else { fail("право .calendars не выдано") }
    printStatus("m1")

    let daysBack = Int(arguments["days-back"] ?? "") ?? 7
    let daysForward = Int(arguments["days-forward"] ?? "") ?? 14
    let calendar = Calendar(identifier: .gregorian)
    let now = Date()
    guard let start = calendar.date(byAdding: .day, value: -daysBack, to: now),
          let end = calendar.date(byAdding: .day, value: daysForward, to: now) else {
        fail("не удалось построить окно")
    }

    let calendars = resolveCalendars(titled: arguments["calendar"])
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
    let events = store.events(matching: predicate)
    let window = "[\(isoFormatter.string(from: start)), \(isoFormatter.string(from: end)))"
    print("m1: событий в окне \(window): \(events.count)")
    fflush(stdout)

    events.forEach(printEvent)
    printSummaryByTitle(events)
}

// MARK: - М2 — калибровка различения «похоже на потерю права» (Р7)

private func runM2(_ arguments: Arguments) async {
    guard await requestAccess() else { fail("право .calendars не выдано") }
    printStatus("m2: до отзыва")

    let waitSeconds = Double(arguments["wait-seconds"] ?? "") ?? 20
    print(
        "m2: \(Int(waitSeconds)) с на отзыв права .calendars — Системные настройки → " +
        "Конфиденциальность и безопасность → Календари (снять галочку у этого носителя), " +
        "либо tccutil reset Calendar <bundle-id-носителя>"
    )
    fflush(stdout)
    try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))

    printStatus("m2: после паузы, до вызова calendars(for:)")
    print(
        "m2: calendars(for:)/events(matching:) в документированном API EventKit — не throws " +
        "(см. `// СТРОКА:` у развилки Р7 в EventKitCoreGateway.swift); если процесс " +
        "завершится ниже без следующей строки — искать причину в .err-логе (NSException " +
        "class/reason)"
    )
    fflush(stdout)

    let calendars = store.calendars(for: .event)
    print("m2: calendars(for: .event) вернул \(calendars.count) календарей — дошли без исключения")
    fflush(stdout)

    let predicate = store.predicateForEvents(withStart: Date(), end: Date().addingTimeInterval(86_400), calendars: nil)
    let events = store.events(matching: predicate)
    print("m2: events(matching:) вернул \(events.count) событий — дошли без исключения")
    fflush(stdout)

    printStatus("m2: после обоих вызовов")
}
