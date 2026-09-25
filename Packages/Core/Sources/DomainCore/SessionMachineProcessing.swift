//  Остановка, отказ и обработка — контракт C-018 (MEE-276), §7 (строки 11—15), §8.4 и §8.7.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧАСТЬ B задачи MEE-300.
//
//  ГДЕ ЧИТАЮТСЯ СТРОКИ 11—15, И ПОЧЕМУ ИМЕННО ТАМ — РЕШЕНИЕ С НАЗВАННОЙ ЦЕНОЙ.
//  §«Поведение» велит «сперва применить пришедшие события, затем пересчитать оценку и цель,
//  затем проверить сроки в порядке строк §7». «Применить» прочитано как «положить пришедшее
//  в состояние, которое читает таблица», а НЕ как «совершить переход прямо в первой фазе».
//  **Довод — К45 (iv) и инвариант 2 вместе:** вход «в `recording` одновременно истинно
//  условие §8.4 и пришёл `CaptureEvent.failed`» делает истинными строки 10 и 11 разом, и
//  инвариант 2 требует победы строки с МЕНЬШИМ номером. При переходе прямо в первой фазе
//  строка 11 побеждала бы всегда, потому что читалась бы раньше строки 10, — то есть
//  порядок таблицы решал бы не порядок таблицы, а номер фазы, и К45 (iv) был бы неисполним
//  ни одной верной реализацией. **Цена выбранного:** событие живёт от своей фазы до фазы
//  сроков того же `tick`, и это состояние, которого при другом чтении не было бы.
//  **Цена отвергнутого:** неисполнимый пункт перечня и молчаливое расхождение с инвариантом 2.
//
//  К39 от этого не страдает и проверяет ровно своё: когда истинна ОДНА строка 11 (цель
//  актуальна, срок §8.4 не наступил), сессия уходит в `failed`, МИНУЯ `stopping`.

import Foundation

extension JobEvent {

    /// Номер задачи, которую несёт событие очереди; `nil` — событие его не несёт.
    /// Нужен затем, чтобы отобрать события ЦЕПОЧКИ ЭТОЙ СЕССИИ прежде чтения строк: без
    /// отбора «порядок таблицы» пришлось бы писать в каждой строке порознь.
    var chainJobId: UUID? {
        switch self {
        case let .submitted(jobId, _):
            return jobId
        case let .started(jobId, _):
            return jobId
        case let .progressed(jobId, _):
            return jobId
        case let .succeeded(jobId, _):
            return jobId
        case let .failed(jobId, _, _, _):
            return jobId
        case let .cancelled(jobId, _):
            return jobId
        case let .blocked(jobId, _, _):
            return jobId
        }
    }
}

extension SessionMachine {

    // MARK: - Фаза сроков: строки 11—15 в порядке таблицы

    /// Строки 11—15 для одной сессии, в порядке таблицы. Ответ — менялось ли состояние:
    /// по нему обход решает, читать ли таблицу этой сессии ещё раз.
    func applyArrivedRows(to session: SessionMachineSession, now: Date) async throws -> Bool {
        switch session.state {
        case .recording:
            // Строка 10 прочитана раньше — она в фазе сроков; здесь строка 11.
            guard hasArrivedCaptureFailure else { return false }
            // MEE-423 (IR-137, C-018 v11 инв. 25): захват уже остановился сам
            // (`CaptureEvent.failed`) — очередь узнаёт об этом здесь, до записи перехода и
            // независимо от её исхода, тем же приёмом, каким `enterStopping` (строка 10)
            // сообщает об остановке до `capture.stop()`.
            await queue.recordingDidStop()
            try await transition(session.sessionId, to: .failed, now: now)
            return true
        case .stopping:
            if let manifest = arrivedManifest(for: session.recordingId) {
                return try await enterProcessing(session.sessionId, manifest: manifest, now: now)
            }
            guard hasArrivedCaptureFailure else { return false }
            try await transition(session.sessionId, to: .failed, now: now)   // строка 13
            return true
        case .processing:
            return try await applyChainEvents(to: session, now: now)
        case .scheduled, .armed, .awaitingSignal, .ready, .failed, .skipped:
            return false
        }
    }

    /// Пришёл ли в этот `tick` отказ захвата. Событие не «принадлежит» сессии: порт захвата
    /// один на приложение, и C-004 отказывает второму `start` (`alreadyRunning`), то есть
    /// идущая запись в каждый момент одна.
    private var hasArrivedCaptureFailure: Bool {
        arrivedCapture.contains { event in
            if case .failed = event { return true }
            return false
        }
    }

    /// Манифест, пришедший событием `stopped` ИМЕННО ЭТОЙ записи.
    private func arrivedManifest(for recordingId: UUID?) -> RecordingManifest? {
        guard let recordingId else { return nil }
        return arrivedCapture
            .compactMap { event -> RecordingManifest? in
                guard case let .stopped(manifest) = event else { return nil }
                return manifest
            }
            .first { $0.recordingId == recordingId }
    }

    // MARK: - §7, строка 12: вход в обработку

    /// Обе клаузы строки 12 обязательны: получен `stopped(manifest)` И запись сохранена.
    ///
    /// Порядок «сохранение записи → вход в `processing` → постановка первой задачи» —
    /// требование К40 и §10 дословно: падение между входом и записью оставило бы запись
    /// нефинализированной, а цепочку — поставленной. Сохранение не состоялось — сессия
    /// остаётся в `stopping`, и решение придёт со следующим `stopped`.
    private func enterProcessing(
        _ identifier: UUID,
        manifest: RecordingManifest,
        now: Date
    ) async throws -> Bool {
        do {
            try await recordings.save(RecordingRecord(manifest: manifest, status: .finalized))
        } catch {
            return false
        }
        try await transition(identifier, to: .processing, now: now)
        await submitChain(.transcode(recordingId: manifest.recordingId), for: identifier, now: now)
        return true
    }

    // MARK: - §7, строки 14 и 15; §8.7: цепочка обработки

    /// Строки 14 и 15 в порядке таблицы и продолжение цепочки §8.7.
    ///
    /// ПОРЯДОК ЗДЕСЬ — ПОРЯДОК ТАБЛИЦЫ, А НЕ ПОРЯДОК ПРИХОДА, И ЭТО ПРАВКА ЧАСТИ C. §7
    /// говорит дословно: «строки проверяются в порядке таблицы: первое подошедшее условие
    /// побеждает», а 14 стоит раньше 15. Часть B читала `arrivedJobs` ОДНИМ проходом и
    /// возвращалась на первом подошедшем событии — то есть при `succeeded` задачи
    /// `attribute` и `cancelled` другой задачи цепочки в ОДИН `tick` побеждала та строка,
    /// чьё событие пришло раньше. Вход этот назван К45 пересечением (ix) поимённо, и ответ
    /// у него один: `ready`, строка 14. Ни один вектор части B его не подавал.
    ///
    /// `blocked` — НЕ отказ: сессия остаётся в `processing`, следующая задача не ставится,
    /// `setStatus` не зовётся (К64). `failed(willRetry: true)` — то же: очередь собирается
    /// повторить, и уводить встречу в `failed` значило бы похоронить её раньше очереди.
    /// Событие чужой задачи не делает ничего: `jobId`, которого машина не ставила, в
    /// `chainJobs` не лежит — на этом стоит «на чужой `attribute` не происходит ничего».
    private func applyChainEvents(to session: SessionMachineSession, now: Date) async throws -> Bool {
        let identifier = session.sessionId
        let mine = arrivedJobs.filter { event in
            guard let jobId = event.chainJobId else { return false }
            return chainJobs[jobId] == identifier
        }

        // Строка 14.
        if mine.contains(where: { event in
            if case let .succeeded(_, type) = event { return type == .attribute }
            return false
        }) {
            try await transition(identifier, to: .ready, now: now)
            return true
        }

        // Строка 15.
        if mine.contains(where: { event in
            switch event {
            case let .failed(_, _, _, willRetry):
                return !willRetry
            case .cancelled:
                return true
            default:
                return false
            }
        }) {
            try await transition(identifier, to: .failed, now: now)
            return true
        }

        // Ни одна строка не подошла — цепочка идёт дальше по `succeeded` предыдущей (§8.7).
        for event in mine {
            guard case let .succeeded(jobId, type) = event else { continue }
            await continueChain(after: jobId, type: type, for: identifier, now: now)
        }
        return false
    }

    /// Следующее звено §8.7 — и только по `succeeded` предыдущего.
    ///
    /// `jobId` разрешается в нагрузку методом `job(id:)` (C-013), поле `Job.payload`:
    /// `JobEvent.succeeded` несёт только `jobId` и тип, и взять `recordingId` из события
    /// нечем. Не разрешился — цепочка не двигается, и это не отказ: сессия остаётся в
    /// `processing`, а событие, не давшее нагрузки, состояния не меняет (инвариант 2).
    private func continueChain(
        after jobId: UUID,
        type: JobType,
        for identifier: UUID,
        now: Date
    ) async {
        guard let next = SessionMachineRules.nextInChain(after: type) else { return }
        guard let done = try? await queue.job(id: jobId),
              let recordingId = recordingId(of: done.payload) else { return }
        guard let payload = await payload(
            for: next, recordingId: recordingId, session: identifier
        ) else { return }
        await submitChain(payload, for: identifier, now: now)
    }

    /// Нагрузка следующей задачи. `profileId` — `AppSettings.defaultProfileId`; `language`
    /// у `transcribe` — `nil`; `transcriptId` для `attribute` берётся ИЗ ХРАНИЛИЩА
    /// (заголовок транскрипта записи, C-010), а `meetingId` равен `meetingId` сессии и
    /// равен `nil` у ad-hoc (К63).
    func payload(
        for type: JobType,
        recordingId: UUID,
        session identifier: UUID
    ) async -> JobPayload? {
        switch type {
        case .transcode:
            return .transcode(recordingId: recordingId)
        case .transcribe:
            return .transcribe(
                recordingId: recordingId, profileId: settings.defaultProfileId, language: nil
            )
        case .diarize:
            return .diarize(recordingId: recordingId, profileId: settings.defaultProfileId)
        case .attribute:
            guard let header = try? await transcripts.latest(recordingId: recordingId) else {
                return nil
            }
            return .attribute(transcriptId: header.id, meetingId: store[identifier]?.meetingId)
        case .summarize:
            // §8.7: в Срезе 1 не ставится — обработчик не зарегистрирован, и задача
            // повисла бы в очереди навсегда (К65). Цепочка сюда не приходит ни одним ходом.
            return nil
        }
    }

    private func recordingId(of payload: JobPayload) -> UUID? {
        switch payload {
        case let .transcode(recordingId):
            return recordingId
        case let .transcribe(recordingId, _, _):
            return recordingId
        case let .diarize(recordingId, _):
            return recordingId
        case .attribute, .summarize:
            return nil
        }
    }

    /// Поставить задачу цепочки и запомнить её за сессией.
    ///
    /// `JobSubmission.standard(_:runAfter:)` с `runAfter == now` — К63 дословно. Настройка
    /// «обрабатывать только от сети» поднимает `requiresACPower` ПРИ ПОСТАНОВКЕ задачи, и
    /// это правило §4 C-013, а не решение этой машины; при `processOnACPowerOnly == false`
    /// подача равна ответу `standard` поле в поле.
    func submitChain(_ payload: JobPayload, for identifier: UUID, now: Date) async {
        var submission = JobSubmission.standard(payload, runAfter: now)
        if settings.processOnACPowerOnly, !submission.conditions.requiresACPower {
            submission = JobSubmission(
                payload: submission.payload,
                priority: submission.priority,
                maxAttempts: submission.maxAttempts,
                runAfter: submission.runAfter,
                conditions: JobConditions(
                    requiresACPower: true,
                    forbidWhileRecording: submission.conditions.forbidWhileRecording,
                    maxThermalPressure: submission.conditions.maxThermalPressure,
                    requiresProfileReady: submission.conditions.requiresProfileReady
                ),
                dedupKey: submission.dedupKey
            )
        }
        guard let jobId = try? await queue.submit(submission) else { return }
        chainJobs[jobId] = identifier
    }
}
