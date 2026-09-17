//  Команды §3.1 машины сессий — контракт C-018 (MEE-276), §3.1, §7 (строки 3, 4, 9, 10, 16),
//  §7.1, §8.2, §8.4 и §«Поведение» («команда сильнее политики и сильнее срока»).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧАСТЬ B задачи MEE-300. Файл отделён от `SessionMachine.swift` по двум доводам, и оба
//  механические: `--strict` линта считает файл длиннее четырёхсот строк нарушением, а тело
//  типа длиннее двухсот — вторым; расширение в тело типа не входит.
//
//  КОМАНДЫ ИСПОЛНЯЮТСЯ В МОМЕНТ ВЫЗОВА, А НЕ НА БЛИЖАЙШЕМ `tick`, и это единственное
//  исключение из «вход, пришедший между двумя `tick`, до `tick` состояния не меняет»
//  (§«Поведение»). Реализация, складывающая команды до следующего `tick`, зелена на всяком
//  векторе, где после команды идёт `tick`, и красна ровно там, где снимок читается МЕЖДУ
//  командой и `tick`, — это и подаёт К58.

import Foundation

extension SessionMachine {

    // MARK: - §3.1: начать запись

    /// `startRecording(meetingId:now:)` — строки 6, 8 и 16 по команде человека.
    ///
    /// Команда сильнее политики: она начинает запись при `recordingPolicy == .manual` и при
    /// висящем спросе (§«Поведение», К58). Единственное, чего она не пересиливает, — §7.1:
    /// цель, занятая идущей записью другой сессии, не отдаётся и команде, и та бросает
    /// `alreadyRecording(sessionId:)` с идентификатором ЗАНИМАЮЩЕЙ сессии (К48).
    public func startRecording(meetingId: UUID?, now: Date) async throws -> UUID {
        guard let meetingId else {
            return try await startAdHocRecording(now: now)
        }
        guard let session = latestSession(meeting: meetingId) else {
            throw SessionError.noSuchMeeting(meetingId: meetingId)
        }
        try requireLive(session)

        // Сессия, которая уже пишет, второй записи не заводит: `recordingId` назначается
        // один раз и дальше не меняется (инвариант 5). Ответ команды — тот же номер.
        if session.state == .recording || session.state == .stopping,
           let recordingId = session.recordingId {
            return recordingId
        }

        let fresh = relatedSignals(for: session, now: now)
        guard let signal = SessionMachineRules.soundingTargetSignal(
            among: fresh.filter { !contested.keys.contains($0.group?.appKey ?? "") },
            sessionProvider: session.event?.conference?.provider
        ), let group = signal.group else {
            throw SessionError.nothingToRecord
        }
        if let occupant = sessionHolding(appKey: group.appKey, excluding: session.sessionId) {
            throw SessionError.alreadyRecording(sessionId: occupant)
        }
        return try await enterRecording(
            session.sessionId, target: group, observedAt: signal.observedAt, now: now
        )
    }

    // MARK: - §3.1: остановить запись

    /// `stopRecording(recordingId:now:)` — вторая половина строки 10.
    ///
    /// Переводит в `stopping` НЕМЕДЛЕННО, в момент вызова, а не на следующем `tick`, и
    /// останавливает запись, которую §8.4 останавливать не собирался (К58).
    public func stopRecording(recordingId: UUID, now: Date) async throws {
        guard let session = store.values.first(where: { $0.recordingId == recordingId }) else {
            throw SessionError.noRecordingInProgress(recordingId: recordingId)
        }
        try requireLive(session)
        guard session.state == .recording else {
            // Запись уже останавливается либо обрабатывается: останавливать нечего, и
            // молчаливым успехом это не является.
            throw SessionError.noRecordingInProgress(recordingId: recordingId)
        }
        try await enterStopping(session.sessionId, now: now)
    }

    // MARK: - §3.1: пропустить встречу

    /// Команда `skip` — строки 3, 4 и 9 таблицы §7.
    ///
    /// Управление не возвращается раньше, чем исход записан `setStatus`-ом (инвариант 18,
    /// вторая половина): запись стоит на пути возврата, а не рядом с ним.
    ///
    /// КЛАУЗУ «КОМАНДА `skip`» НЕСУТ ТОЛЬКО ТРИ СТРОКИ — 3, 4 и 9, — и потому из состояний
    /// записи и обработки эта команда состояния НЕ МЕНЯЕТ: строки, которая увела бы сессию
    /// из `recording`, `stopping` или `processing` в `skipped`, в таблице нет ни одной, а
    /// инвариант 2 объявляет иные переходы запрещёнными. Ошибки при этом не даётся —
    /// тотальность того же инварианта. Названо здесь, а не умолчано: остановку идущей записи
    /// человек просит командой `stopRecording`, и она у него есть.
    public func skip(meetingId: UUID, now: Date) async throws {
        guard let session = latestSession(meeting: meetingId) else {
            throw SessionError.noSuchMeeting(meetingId: meetingId)
        }
        try requireLive(session)
        switch session.state {
        case .scheduled, .armed, .awaitingSignal:
            try await transition(session.sessionId, to: .skipped, now: now)
        case .recording, .stopping, .processing, .ready, .failed, .skipped:
            return
        }
    }

    // MARK: - §3.1: ответ на спрос §8.2 и §8.6

    /// Ответ `.skip` уводит сессию в `skipped` (строки 4, 9). Ответ `.record` открывает
    /// политику `.ask`, а у ad-hoc-сессии — уводит её в `recording` строкой 16 (§8.6).
    public func answer(promptId: UUID, _ answer: SessionPromptAnswer, now: Date) async throws {
        guard let stored = raised[promptId] else {
            throw SessionError.noSuchPrompt(promptId: promptId)
        }
        guard let session = store[stored.prompt.sessionId] else {
            throw SessionError.noSuchSession(sessionId: stored.prompt.sessionId)
        }
        // Порядок существен: К6 требует `sessionIsTerminal`, а НЕ `noSuchPrompt`, — значит
        // терминальность читается прежде, чем снятость спроса.
        try requireLive(session)
        guard !stored.isWithdrawn else {
            throw SessionError.noSuchPrompt(promptId: promptId)
        }
        switch answer {
        case .skip:
            try await transition(session.sessionId, to: .skipped, now: now)
        case .record:
            try await applyRecordAnswer(to: session, promptId: promptId, now: now)
        }
    }

    /// Ответ `.record`, разведённый по двум случаям, потому что контракт разводит их сам.
    ///
    /// **Ad-hoc (§8.6):** ответ уводит сессию в `recording` строкой 16 — то есть в момент
    /// вызова. **Сессия с событием (§8.2):** ответ ОТКРЫВАЕТ политику, а запись начинают
    /// строки 6 и 8 на ближайшем `tick`. Решение названо, а не умолчано: §8.2 говорит
    /// «строки 6 и 8 срабатывают только после ответа `.record`» — то есть переход остаётся
    /// строкой таблицы, а строки читаются в фазе сроков. **Цена: запись начинается на один
    /// `tick` позже ответа**, и предел этого опоздания назван §8.5. **Цена отвергнутого
    /// (начинать в момент ответа): решение принималось бы по цели, снятой предыдущим
    /// `tick`, — то есть по возможно уже неактуальному сигналу.**
    private func applyRecordAnswer(
        to session: SessionMachineSession,
        promptId: UUID,
        now: Date
    ) async throws {
        var updated = session
        updated.recordAnswered = true
        updated.updatedAt = now
        store[session.sessionId] = updated
        withdrawPrompt(promptId)

        guard session.origin == .adHoc else { return }
        guard let group = session.target,
              let signal = actualSignal(appKey: group.appKey, now: now) else {
            // Цель ушла, пока человек думал: спрашивать больше не о чем, и §8.6 уводит
            // такую сессию в `skipped` — тем же исходом, что и снятие спроса по причине.
            try await transition(session.sessionId, to: .skipped, now: now)
            return
        }
        if let occupant = sessionHolding(appKey: group.appKey, excluding: session.sessionId) {
            throw SessionError.alreadyRecording(sessionId: occupant)
        }
        _ = try await enterRecording(
            session.sessionId, target: group, observedAt: signal.observedAt, now: now
        )
    }
}
