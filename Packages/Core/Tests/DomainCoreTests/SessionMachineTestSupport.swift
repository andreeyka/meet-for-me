//  Оснастка тестов машины сессий — MEE-298, часть A.
//
//  ИМПОРТ С `@testable`, И ЭТО РЕШЕНИЕ С НАЗВАННОЙ ЦЕНОЙ. Тесты подают вход через потоки
//  портов, а доставка из `AsyncStream` в машину асинхронна ПО ПОСТРОЕНИЮ: синхронного
//  способа забрать элемент у `AsyncStream` нет ни одного. Тест, подавший сигнал и сразу
//  позвавший `tick`, проверял бы расписание исполнителя, а не машину, — и был бы зелен или
//  красен по времени. Поэтому он ждёт ровно того события, которого ждёт: `mailbox`
//  внутримодулен, и `@testable` открывает его. **Цена названа:** прочие тесты этого каталога
//  импортируют `DomainCore` без `@testable` намеренно, и здесь эта привычка нарушена; взамен
//  ни один пункт не стоит на пределе времени, кроме того единственного, которому план
//  MEE-288 §2 отвёл условие `Р`, — К81 (iii).
//
//  ПОЧЕМУ ОЖИДАНИЕ НА ПРОДОЛЖЕНИИ, А НЕ НА ТАЙМАУТЕ. §7 плана: «предел, взятый короче
//  задержки, красит верную реализацию; взятый длиннее — зеленит неверную». Продолжение
//  возобновляется тем самым событием, которого ждут, и потому предела не требует вовсе.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

/// Стенд: машина и все её порты на одном журнале вызовов (условие `Н` плана MEE-288 §2).
struct SessionMachineBench {

    let log: PortCallLog
    let processes: FakeProcessMonitorPort
    let calendar: FakeCalendarPort
    let repositories: InMemoryRepositories
    let capture: FakeAudioCapturePort
    let queue: FakeJobQueue
    let power: FakePowerPort
    let machine: SessionMachine

    var meetings: InMemoryMeetingRepository { repositories.meetings }

    init(settings: AppSettings, weights: SignalWeights) {
        let shared = PortCallLog()
        log = shared
        processes = FakeProcessMonitorPort()
        calendar = FakeCalendarPort(log: shared)
        repositories = InMemoryRepositories(log: shared)
        capture = FakeAudioCapturePort(log: shared)
        queue = FakeJobQueue(log: shared)
        power = FakePowerPort(snapshot: SessionMachineFixtures.powerSnapshot, log: shared)
        machine = SessionMachine(
            processes: processes,
            calendar: calendar,
            meetings: repositories.meetings,
            capture: capture,
            queue: queue,
            power: power,
            settings: settings,
            weights: weights
        )
    }

    /// Дождаться, пока ящик машины примет `total` входов за свою жизнь. Ровно то событие,
    /// которого ждут; предела времени здесь нет ни одного.
    func awaitDelivery(_ total: Int) async {
        await machine.mailbox.waitUntilReceived(total)
    }

    /// Положить встречу в хранилище — вход теста, а не вызов порта.
    func seed(_ event: MeetingEvent, status: MeetingStatus = .scheduled) {
        repositories.meetings.seed([
            MeetingRecord(event: event, dedupKey: nil, status: status, sources: [])
        ])
    }
}

/// Значения, которые тесты подают машине.
enum SessionMachineFixtures {

    static let powerSnapshot = PowerSnapshot(
        source: .ac,
        batteryFraction: nil,
        isLowPowerModeEnabled: false,
        thermalPressure: .nominal,
        checkedAt: Date(timeIntervalSince1970: 0)
    )

    /// Опорный момент всех векторов. Число выбрано читаемым, а не значимым: сроки считаются
    /// от него арифметикой, и ни один ответ от его величины не зависит.
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Настройки со значениями, ОТЛИЧНЫМИ от умолчаний C-016 (120, 30, 900, 300) — К19, К49,
    /// К70 требуют именно этого: поведение обязано идти вслед за значениями, а не за числом
    /// в коде. Умолчаний у `AppSettings` в дереве нет вовсе (находка MEE-289), и собирается
    /// значение здесь целиком.
    static func settings(
        policy: AppSettings.RecordingPolicy = .auto,
        armLead: Int = 600,
        askLead: Int = 90,
        grace: Int = 1200,
        silence: Int = 240
    ) -> AppSettings {
        AppSettings(
            recordingPolicy: policy,
            armLeadSeconds: armLead,
            askLeadSeconds: askLead,
            missingSignalGraceSeconds: grace,
            silenceStopSeconds: silence,
            defaultProfileId: "profile-1",
            processOnACPowerOnly: false,
            processWhileRecording: true,
            audioRetentionDays: nil,
            voiceProfilesEnabled: false,
            notifyParticipants: false,
            launchAtLogin: false
        )
    }

    /// Значения таблицы весов — ЧЕРЕЗ ПУБЛИЧНЫЙ ЧЛЕН, отдающий прочитанные значения
    /// (`SignalWeights.values(from:)`, C-009 §6). Файла тест не подменяет и пути к нему не
    /// знает: подменяется вход чистой функции, а не ресурс.
    static func weights(
        calendarWindow: Double = 0.2,
        clientRunning: Double = 0.4,
        clientAudioOutput: Double = 0.8,
        microphoneInUse: Double = 0.4,
        signalTtlSeconds: Int = 60
    ) throws -> SignalWeights {
        let json = """
        {"schemaVersion": 1, "signalTtlSeconds": \(signalTtlSeconds), "weights": \
        {"calendarWindow": \(calendarWindow), "clientRunning": \(clientRunning), \
        "clientAudioOutput": \(clientAudioOutput), "microphoneInUse": \(microphoneInUse)}}
        """
        return try SignalWeights.values(from: Data(json.utf8))
    }

    /// Событие с названными полями. Всё прочее — наполнение, от которого ни один ответ
    /// машины не зависит.
    static func event(
        id: UUID = UUID(),
        start moment: Date = SessionMachineFixtures.start,
        duration: TimeInterval = 1800,
        isAllDay: Bool = false,
        isCancelled: Bool = false,
        provider: String? = "zoom"
    ) throws -> MeetingEvent {
        try MeetingEvent(
            id: id,
            sourceConnectorId: "eventkit",
            externalId: "evt-\(id.uuidString.prefix(8))",
            icalUid: nil,
            title: "Созвон",
            start: moment,
            end: moment.addingTimeInterval(duration),
            timeZone: "Europe/Moscow",
            isAllDay: isAllDay,
            isCancelled: isCancelled,
            organizer: nil,
            attendees: [],
            location: nil,
            bodyText: nil,
            conference: try provider.map {
                try MeetingEvent.Conference(
                    provider: $0,
                    joinUrl: URL(string: "https://example.com/j/1")!,
                    meetingId: nil,
                    passcode: nil
                )
            },
            lastModified: moment
        )
    }

    /// Сигнал `clientAudioOutput` с группой — звучащая цель по §5.3.
    static func audioOutput(
        appKey: String,
        provider: String? = "zoom",
        observedAt: Date,
        weight: Double = 0.8,
        pid: Int32 = 501
    ) -> MeetingSignal {
        MeetingSignal(
            kind: .clientAudioOutput,
            weight: weight,
            pid: pid,
            bundleId: appKey,
            group: ProcessGroup(appKey: appKey, pids: [pid], observedAt: observedAt),
            provider: provider,
            meetingId: nil,
            observedAt: observedAt
        )
    }

    /// Сигнал произвольного вида. `group == nil` — законный вход от сломанного адаптера.
    static func signal(
        kind: MeetingSignalKind,
        weight: Double,
        appKey: String?,
        provider: String? = nil,
        observedAt: Date,
        pid: Int32 = 601
    ) -> MeetingSignal {
        MeetingSignal(
            kind: kind,
            weight: weight,
            pid: kind == .calendarWindow ? nil : pid,
            bundleId: appKey,
            group: appKey.map { ProcessGroup(appKey: $0, pids: [pid], observedAt: observedAt) },
            provider: provider,
            meetingId: nil,
            observedAt: observedAt
        )
    }
}

/// Собрать из потока `changes()` то, что уже в нём лежит, не дожидаясь продолжения.
/// Читает ровно `count` элементов: поток бесконечен, и «дочитать до конца» у него нет смысла.
func collect(_ stream: AsyncStream<SessionChange>, count: Int) async -> [SessionChange] {
    var taken: [SessionChange] = []
    guard count > 0 else { return taken }
    for await change in stream {
        taken.append(change)
        if taken.count == count { break }
    }
    return taken
}

extension SessionChange {

    /// Снимок сессии, если это он.
    var session: SessionSnapshot? {
        if case let .session(snapshot) = self { return snapshot }
        return nil
    }

    var raisedPrompt: SessionPrompt? {
        if case let .promptRaised(prompt) = self { return prompt }
        return nil
    }

    var withdrawnPromptId: UUID? {
        if case let .promptWithdrawn(promptId) = self { return promptId }
        return nil
    }
}
