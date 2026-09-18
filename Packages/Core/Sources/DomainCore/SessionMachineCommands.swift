//  Команды §3.1 машины сессий — контракт C-018 (MEE-276), §3.1, §7 (строки 3, 4, 9, 10, 16),
//  §7.1, §8.2, §8.4 и §«Поведение» («команда сильнее политики и сильнее срока»).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧАСТЬ B задачи MEE-300. Файл отделён от `SessionMachine.swift` по двум доводам, и оба
//  механические: `--strict` линта считает файл длиннее четырёхсот строк нарушением, а тело
//  типа длиннее двухсот — вторым; расширение в тело типа не входит.
//
//  КАЖДАЯ КОМАНДА НАЧИНАЕТСЯ С `absorbArrivals()`, И ЭТО НЕ ОСНАСТКА. Команда исполняется
//  В МОМЕНТ ВЫЗОВА, а вход §2 приходит потоком и лежит в ящике до ближайшего `tick`:
//  команда, не забравшая ящик, решает по миру, каким он был на прошлом ходу. Цена этого
//  не бумажная — §8.6 ставит условие заведения на «такой сигнал ЕСТЬ», и `startRecording
//  (meetingId: nil)`, поданная до первого `tick` по сигналу, ответила бы `nothingToRecord`
//  на созвон, который в эту минуту звучит (К95, вектор (б′); К44). Состояния ни одной
//  сессии `absorbArrivals()` при этом не меняет — разбор и граница в его шапке.
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
    /// КОМАНДА ОТДАЁТ ЦЕЛЬ, А УВОДИТ СЕССИЮ СТРОКА ТАБЛИЦЫ, И ЭТО ПРАВКА ПОД v7. §8.2
    /// дословно: «Отдаёт цель команда `startRecording(meetingId:)` — и с момента её вызова
    /// третья клауза строк 6 и 8 („запись разрешена политикой“) истинна, сессия уходит в
    /// `recording` строкой 6 либо 8, ровно тем же способом, каким при `.ask` её уводит
    /// ответ `.record`». Прежняя редакция §8.2 отвечала на этот вход двумя способами в
    /// одном предложении — «строки 6 и 8 не срабатывают никогда» и той же скобкой «команда
    /// даёт цель, и та уходит строкой 6 либо 8», — и часть B исполняла первую половину:
    /// записывала ПОМИМО таблицы. Такая реализация даёт верное конечное состояние,
    /// нарушает инвариант 2 («всякий иной переход запрещён») и краснеет К52, К34 (пятый
    /// вектор) и К36 (i, пятый вектор), которым номер строки есть часть Ответа.
    ///
    /// КЛАУЗА ОТКРЫВАЕТСЯ ДО ПРОВЕРКИ §7.1, А НЕ ПОСЛЕ, и это чтение «с момента её вызова»
    /// дословно: клауза третья — про ПОЛИТИКУ, а занятость цели есть клауза вторая, и
    /// команда, упёршаяся во вторую, первой не отменяет. Отсюда: цель, освободившаяся
    /// позже, уводит сессию строкой 6 либо 8 ближайшим `tick` без второй команды.
    ///
    /// Команда сильнее политики: она начинает запись при `recordingPolicy == .manual` и при
    /// висящем спросе (§«Поведение», К58). Единственное, чего она не пересиливает, — §7.1:
    /// цель, занятая идущей записью другой сессии, не отдаётся и команде, и та бросает
    /// `alreadyRecording(sessionId:)` с идентификатором ЗАНИМАЮЩЕЙ сессии (К48).
    public func startRecording(meetingId: UUID?, now: Date) async throws -> UUID {
        absorbArrivals()
        guard let meetingId else {
            return try await startAdHocRecording(now: now)
        }
        guard var session = latestSession(meeting: meetingId) else {
            throw SessionError.noSuchMeeting(meetingId: meetingId)
        }
        try requireLive(session)

        // Сессия, которая уже пишет, второй записи не заводит: `recordingId` назначается
        // один раз и дальше не меняется (инвариант 5). Ответ команды — тот же номер.
        if session.state == .recording || session.state == .stopping,
           let recordingId = session.recordingId {
            return recordingId
        }

        session.commandGaveTarget = true
        session.updatedAt = now
        store[session.sessionId] = session

        let fresh = relatedSignals(for: session, now: now)
            .filter { !$0.relation.isDisputeParty || !contested.keys.contains($0.signal.group?.appKey ?? "") }
            .map(\.signal)
        guard let signal = SessionMachineRules.soundingTargetSignal(
            among: fresh,
            sessionProvider: session.event?.conference?.provider
        ), let group = signal.group else {
            // СТРОКА: чем `startRecording(meetingId:)` отвечает сессии события без звучащей
            // цели, издание v7 не называет (§«Ломающие изменения против v6»); владелец —
            // архитектор C-018, срок «не позже выдачи части C». Исходов два законных —
            // отказ и молчание; дерево выбрало ОТКАЗ частью B, и часть C его не меняет.
            throw SessionError.nothingToRecord
        }
        if let occupant = sessionHolding(appKey: group.appKey, excluding: session.sessionId) {
            throw SessionError.alreadyRecording(sessionId: occupant)
        }
        guard let row = SessionMachineRules.commandRow(from: session.state) else {
            // СТРОКА: та же, что выше. Строк 6 и 8 нет ни одной из `scheduled` и из
            // `processing`, и переход помимо таблицы запрещён инвариантом 2; отказ здесь
            // есть тот же выбор реализатора, названный строкой архитектора.
            throw SessionError.nothingToRecord
        }
        // Цель, выбранная В МОМЕНТ ВЫЗОВА, кладётся сессии прежде строки: строка 6 и
        // строка 8 читают `target` сессии, а последний пересчёт был на прошлом `tick` и
        // мог видеть другой сигнал (К52, клауза Входа об актуальности).
        session.target = group
        session.lastTargetObservedAt = signal.observedAt
        store[session.sessionId] = session

        try await applyDeadlineRow(row, to: session, now: now)
        guard let recordingId = store[session.sessionId]?.recordingId else {
            throw SessionError.nothingToRecord
        }
        return recordingId
    }

    // MARK: - §3.1: остановить запись

    /// `stopRecording(recordingId:now:)` — вторая половина строки 10.
    ///
    /// Переводит в `stopping` НЕМЕДЛЕННО, в момент вызова, а не на следующем `tick`, и
    /// останавливает запись, которую §8.4 останавливать не собирался (К58).
    public func stopRecording(recordingId: UUID, now: Date) async throws {
        absorbArrivals()
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
        absorbArrivals()
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
        absorbArrivals()
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
        // СТРОКОЙ 8, А НЕ 16: издание v6 сняло ответ `.record` из строки 16 и оставило там
        // одну команду. Сессия уже заведена строкой 1в и стоит в `awaitingSignal`; ответ
        // отдаёт ей цель, и уводит её строка таблицы (§8.6; К36 (ii), К44 вектор (а)).
        updated.target = group
        updated.lastTargetObservedAt = signal.observedAt
        store[session.sessionId] = updated
        try await applyDeadlineRow(.row8AwaitingSignalToRecording, to: updated, now: now)
    }
}
