//  Восстановление после перезапуска приложения — контракт C-018 (MEE-276), §10, перечни А
//  и Б; §8.7 (восстановительный вход в цепочку); инварианты 2, 18, 20, 22 и 24.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧАСТЬ C задачи MEE-307.
//
//  `start(now:)` НЕ ИСПОЛНЯЕТ НИ ОДНОГО СРОКА, И ЭТО ПЕРВОЕ, ЧТО НАДО ЗНАТЬ ОБ ЭТОМ ФАЙЛЕ.
//  Он читает хранилище, приводит `RecordingStatus` к фактическому состоянию, заводит сессии
//  перечнями А и Б — и на этом кончается. Всякий срок, уже прошедший к моменту
//  `start(now:)`, исполняется ПЕРВЫМ `tick(now:)` после него, строками таблицы §7 в их
//  порядке (§10, издание v6; инвариант 14). **Цена названа контрактом и она наблюдаема:**
//  потребитель, прочитавший `changes()` МЕЖДУ `start(now:)` и первым `tick`, увидит сессию
//  в `awaitingSignal`, чей `graceEndsAt` уже прошёл, — и снимок этот ВЕРЕН, то есть не
//  противоречит таблице. Ровно это подаёт К46 третьим видом входа, и реализация,
//  исполняющая сроки внутри `start`, публикует там один снимок вместо двух.
//
//  ЧТО ЗАСТАВЛЯЕТ ПЕРВЫЙ `tick` ПРИЙТИ НЕМЕДЛЕННО, лежит не здесь, а в `nextDeadline(now:)`:
//  сессия, заведённая при уже прошедшем сроке, даёт срок В ПРОШЛОМ, а §8.5 обязывает
//  composition root звать `tick` не позже ближайшего `nextDeadline(now:)`. Второй
//  обязанности этим не заводится ни одной — исполняется уже стоящая.
//
//  ЗАВЕДЕНИЙ ВНЕ ТАБЛИЦЫ §7 ЗДЕСЬ РОВНО ДВА, И ТРЕТЬЕГО НЕТ (инвариант 2, названное
//  исключение): вход в `processing` и вход в `failed`, оба в перечне А. Перечень Б третьего
//  не заводит — и это издание v7, сказанное контрактом прямо: встрече в `recording`,
//  `stopping` либо `processing`, у которой нет НИ ОДНОЙ записи, машина ставит `failed` и
//  называет это в логе, а сессии не заводит ни одной; `setStatus` зовётся тут БЕЗ СЕССИИ,
//  потому что менять состояние нечему (К78, К46 вид 2).

import Foundation

extension SessionMachine {

    // MARK: - §10: порядок перечней

    /// Восстановление из хранилища. Перечни читаются в названном порядке: СПЕРВА ЗАПИСИ
    /// (перечень А), ПОТОМ ВСТРЕЧИ (перечень Б), и порядок этот проверяется (К78).
    ///
    /// **Два перечня не спорят по построению:** А решает судьбу ЗАПИСИ, Б — судьбу ВСТРЕЧИ,
    /// и встреча в `recording`, `stopping` или `processing` берёт свой исход из А, а не
    /// решает его сама. Пара «встреча в `ready` при записи в `.recording`» разрешается в
    /// пользу А: сессия входит в `processing` и доводит цепочку, а `setStatus` приводит
    /// встречу к фактическому состоянию (инвариант 18, К79).
    func recoverFromStorage(now: Date) async {
        let handled = await recoverRecordings(now: now)
        await recoverMeetings(handled: handled, now: now)
    }

    // MARK: - §10, перечень А: по записям

    /// Перечень А. Ответ — записи, судьбу которых он решил: перечень Б их не перерешает.
    ///
    /// Читается `unfinalized()` (C-010) — предикат «`RecordingStatus` не равен
    /// `.finalized`», то есть ровно `.recording`, `.stopping` и `.failed`. Записи в
    /// `.finalized` в этот ответ не входят вовсе, и разбирает их перечень Б через встречу,
    /// которой они принадлежат.
    ///
    /// СТРОКА: записи в `.finalized` с `manifest.meetingId == nil` (ad-hoc) не достижимы
    /// ничем. `unfinalized()` их не отдаёт, а перечня всех записей C-010 не объявляет ни
    /// одним методом: `recording(id:)` требует номера, `recordings(meetingId:)` — встречи,
    /// которой у ad-hoc-записи нет (§1.3). Отсюда ad-hoc-запись, чья цепочка оборвалась
    /// ПОСЛЕ финализации, остаётся в `processing`-без-сессии навсегда. **Владелец —
    /// архитектор C-018** (перечень А тотален по `RecordingStatus`, а средства обойти его
    /// нет), **условие снятия:** либо C-010 объявляет чтение записей без встречи, либо §10
    /// называет читателя `.finalized` поимённо. **Срок — ближайшее издание C-018.** Живой
    /// вход у неё есть: ad-hoc-запись, дошедшая до `processing`, и перезапуск после него.
    private func recoverRecordings(now: Date) async -> Set<UUID> {
        var handled: Set<UUID> = []
        let unfinalized = (try? await recordings.unfinalized()) ?? []
        for record in unfinalized.sorted(by: { SessionMachineOrder.ascending(
            $0.manifest.recordingId, $1.manifest.recordingId
        ) }) {
            handled.insert(record.manifest.recordingId)
            switch record.status {
            case .recording, .stopping:
                await recoverInterrupted(record, now: now)
            case .failed:
                // Сессии не заводит. Строка уже в терминальном для записи состоянии,
                // и приводить её не к чему.
                continue
            case .finalized:
                // В ответ `unfinalized()` не входит по его предикату; ветвь оставлена ради
                // тотальности перебора по `RecordingStatus` (инвариант 22).
                continue
            }
        }
        return handled
    }

    /// `.recording` и `.stopping`: `recover(directory:)` (C-004), затем приведение статуса,
    /// затем сессия.
    ///
    /// ПОРЯДОК ЗДЕСЬ НЕСУЩИЙ И НАБЛЮДАЕМ ЖУРНАЛОМ ВЫЗОВОВ, А НЕ КОНЕЧНЫМ СОСТОЯНИЕМ.
    /// Машина СПЕРВА приводит `RecordingStatus` этой записи к `.finalized`
    /// (`RecordingRepository.save(_:)`, C-010, с ВОССТАНОВЛЕННЫМ манифестом) И ТОЛЬКО ЗАТЕМ
    /// вводит сессию в `processing` и ставит первую недошедшую задачу (К77, К92). Довод тот
    /// же, что в инварианте 18: падение между ними оставило бы запись нефинализированной, а
    /// цепочку — поставленной.
    ///
    /// ПОЧЕМУ СТАТУС ПРИВОДИТ МАШИНА. C-010 («Поведение») говорит, что строка `recordings`
    /// со статусом `recording` при старте означает прерванную запись, что обработка есть
    /// обязанность ДОМЕНА, а не репозитория, и что `unfinalized()` существует именно для
    /// этого. До издания v4 §10 оставлял строку в `.recording`, и та же запись возвращалась
    /// из `unfinalized()` при каждом следующем запуске — `recover` звался на ней снова, а
    /// запись не финализировалась никогда (К77, различающий вектор издания v4).
    ///
    /// ОТКАЗ ЧИТАЕТСЯ ЛЮБОЙ, А НЕ ТОЛЬКО `recoveryFailed`, и это названо, а не умолчано.
    /// §10 называет `recoveryFailed` поимённо, потому что он единственный, ради которого
    /// `recover` объявлен; прочие `CaptureError` он не разбирает. Взято: всякий отказ
    /// `recover` ведёт в ту же ветвь — запись к `.failed`, сессия в `failed`. **Довод:**
    /// исход «удалось» стоит на ВОЗВРАЩЁННОМ манифесте, и там, где манифеста нет, второй
    /// ветви взяться неоткуда; молчаливое проглатывание прочих отказов оставило бы запись
    /// в `.recording` навсегда — ровно тот дефект, который издание v4 чинило.
    private func recoverInterrupted(_ record: RecordingRecord, now: Date) async {
        let recordingId = record.manifest.recordingId
        do {
            let recovered = try await capture.recover(directory: recordingDirectory(recordingId))
            try await recordings.save(RecordingRecord(manifest: recovered, status: .finalized))
            await openRecovered(manifest: recovered, state: .processing, now: now)
            await submitFirstUnreached(recordingId: recovered.recordingId, now: now)
        } catch {
            try? await recordings.save(RecordingRecord(manifest: record.manifest, status: .failed))
            await openRecovered(manifest: record.manifest, state: .failed, now: now)
        }
    }

    // MARK: - §10, перечень Б: по встречам

    /// Перечень Б, тотальный по девяти значениям `MeetingStatus` (инвариант 22).
    private func recoverMeetings(handled: Set<UUID>, now: Date) async {
        let from = now.addingTimeInterval(-TimeInterval(settings.missingSignalGraceSeconds))
        let stored = (try? await meetings.meetings(from: from, to: Date.distantFuture)) ?? []
        var openable: [MeetingRecord] = []
        for record in stored.sorted(by: { SessionMachineOrder.ascending($0.event.id, $1.event.id) }) {
            storedStatuses[record.event.id] = record.status
            if knownEvents[record.event.id] == nil {
                knownEvents[record.event.id] = record.event
            }
            switch record.status {
            case .scheduled, .armed, .awaitingSignal:
                openable.append(record)
            case .recording, .stopping, .processing:
                await recoverMeetingByRecording(record, handled: handled, now: now)
            case .ready, .failed, .skipped:
                // Сессия не заводится, и это СЛЕДСТВИЕ, а не второе правило: §9.1 не
                // заводит сессии для встречи с терминальным `MeetingStatus` (инвариант 24),
                // и `start(now:)` здесь не исключение. Строка оставлена ради тотальности
                // перечня (инвариант 22, К78, К91).
                continue
            }
        }
        await openRestored(openable, now: now)
    }

    /// `recording`, `stopping`, `processing`: судьбу определяет ЗАПИСЬ этой встречи.
    ///
    /// Запись уже разобрана перечнем А — второй раз её никто не трогает. Осталась она в
    /// `.finalized` — разбирается здесь, потому что `unfinalized()` её не отдаёт.
    ///
    /// ЗАПИСЕЙ У ВСТРЕЧИ НЕТ НИ ОДНОЙ — СТАТУС ВСТРЕЧИ ЛОЖЕН: машина ставит `failed` и
    /// называет это в логе; иного способа отличить «запись потеряна» от «статус не
    /// дописан» у неё нет. **Сессии при этом не заводится НИ ОДНОЙ** (издание v7):
    /// заведений вне таблицы ровно два, оба в перечне А, и перечень Б третьего не заводит.
    /// Реализация, заводящая здесь сессию в `failed`, даёт ТРИ заведения вне таблицы и
    /// краснеет К46 видом 2, исполняя прежнюю редакцию §10 дословно (К78).
    private func recoverMeetingByRecording(
        _ record: MeetingRecord,
        handled: Set<UUID>,
        now: Date
    ) async {
        let owned = (try? await recordings.recordings(meetingId: record.event.id)) ?? []
        guard !owned.isEmpty else {
            try? await meetings.setStatus(.failed, meetingId: record.event.id)
            storedStatuses[record.event.id] = .failed
            return
        }
        for recording in owned.sorted(by: { SessionMachineOrder.ascending(
            $0.manifest.recordingId, $1.manifest.recordingId
        ) }) where !handled.contains(recording.manifest.recordingId) {
            guard recording.status == .finalized else { continue }
            await recoverFinalized(recording, now: now)
        }
    }

    /// `.finalized`: сессия входит в `processing` ТОГДА И ТОЛЬКО ТОГДА, когда цепочка §8.7
    /// этой записи не дошла до успешной `attribute` И ни одна её задача не завершилась
    /// отказом или отменой.
    ///
    /// Определяется это ЗАДАЧАМИ ЗАПИСИ (`jobs(status:)`, C-013), а не статусом встречи, —
    /// и теми же задачами §8.7 выбирает первую недошедшую: второго чтения и второго
    /// источника не заводится. Есть задача, завершившаяся отказом или отменой, — сессия
    /// входит в `failed`: это тот же исход, который строка 15 даёт живой машине, и
    /// повторную обработку заводит команда пользователя, а не восстановление (К77).
    private func recoverFinalized(_ record: RecordingRecord, now: Date) async {
        let jobs = await jobsOfChain(recordingId: record.manifest.recordingId)
        if jobs.contains(where: { $0.status == .failed || $0.status == .cancelled }) {
            await openRecovered(manifest: record.manifest, state: .failed, now: now)
            return
        }
        let done = jobs.filter { $0.status == .succeeded }.map(\.type)
        guard !done.contains(.attribute) else { return }
        await openRecovered(manifest: record.manifest, state: .processing, now: now)
        await submitFirstUnreached(recordingId: record.manifest.recordingId, now: now)
    }

    // MARK: - §9.1: перечень Б, первая строка

    /// `scheduled`, `armed`, `awaitingSignal`: сессия заводится ЗАНОВО ПО §9.1, и все сроки
    /// считаются от `now`.
    ///
    /// «По §9.1» здесь дословно: то же единственное условие заведения, включая клаузу о
    /// хранимом `MeetingStatus`, и то же состояние-функция от `now` — строки 1, 1а, 1б.
    /// Второго правила заведения §10 не пишет ни одного, и потому здесь зовётся та же
    /// `openSessions(now:)`, которой заводит `tick`, а не её копия.
    ///
    /// ПОДНЯТЫЙ ДО ПЕРЕЗАПУСКА СПРОС НЕ ВОССТАНАВЛИВАЕТСЯ: ответ на него нигде не хранится
    /// (§8.2), и при `.ask` он поднимается ЗАНОВО — в момент заведения, если `askAt` уже
    /// прошёл (К80 ветвь (а), К93). Этим занимается `raiseDuePrompts(now:)`, и зовётся он
    /// здесь, а не первым `tick`, потому что К80 и К93 наблюдают спрос сразу после `start`.
    ///
    /// ПОЧЕМУ ПЕРЕСЧЁТ ЦЕЛИ ЗДЕСЬ ЕСТЬ, А СРОКОВ НЕТ. `recompute(now:)` сроков не
    /// исполняет — он считает оценку и звучащую цель, то есть заполняет поля снимка,
    /// который вот-вот уйдёт в `changes()`. Без него заведённая сессия ушла бы наружу с
    /// пустым `target` и нулевым `estimate`, и снимок был бы ложен на свой же момент.
    /// Сроков не исполняется ни одного: `runDeadlines(now:)` здесь не зовётся.
    private func openRestored(_ records: [MeetingRecord], now: Date) async {
        let opened = await openSessions(
            now: now,
            readingStorage: false,
            limitedTo: Set(records.map(\.event.id))
        )
        recompute(now: now)
        for identifier in opened {
            guard let session = store[identifier] else { continue }
            hub.publish(.session(snapshot(of: session)))
        }
        raiseDuePrompts(now: now)
    }

    // MARK: - Заведение вне таблицы — два способа, и третьего нет

    /// Восстановительное заведение сессии перечнем А: вход в `processing` и вход в `failed`.
    ///
    /// `origin` берётся из `manifest.meetingId`: `nil` — `.adHoc` (К77, К97 ветвь (б)), и
    /// этим держится инвариант 4 первой половиной — `meetingId == nil` тогда и только
    /// тогда, когда `origin == .adHoc`.
    ///
    /// ИНВАРИАНТ 18 ИСПОЛНЕН ЗДЕСЬ ЖЕ, И ПОРЯДОК ЗНАЧИМ: `setStatus` идёт ПРЕЖДЕ публикации
    /// снимка, иначе потребитель, прочитавший хранилище по событию, прочтёт прежнее
    /// значение (К81). У ad-hoc-сессии `setStatus` не зовётся ни разу — `meetingId` у неё
    /// `nil`, и менять нечего (К95, К81 вход (iv)).
    private func openRecovered(manifest: RecordingManifest, state: MeetingStatus, now: Date) async {
        let identifier = UUID()
        if let meetingId = manifest.meetingId {
            try? await meetings.setStatus(state, meetingId: meetingId)
            storedStatuses[meetingId] = state
        }
        let session = SessionMachineSession(
            sessionId: identifier,
            origin: manifest.meetingId == nil ? .adHoc : .scheduled,
            meetingId: manifest.meetingId,
            state: state,
            recordingId: manifest.recordingId,
            target: nil,
            estimate: 0,
            enteredStateAt: now,
            updatedAt: now,
            event: manifest.meetingId.flatMap { knownEvents[$0] },
            promptId: nil,
            recordAnswered: false,
            commandGaveTarget: false,
            adHocAppKey: nil,
            lastTargetObservedAt: nil,
            powerToken: nil
        )
        store[identifier] = session
        hub.publish(.session(snapshot(of: session)))
    }

    // MARK: - §8.7: восстановительный вход ставит задачу сам

    /// Первая недошедшая задача цепочки — РОВНО ОДНА, и это второй из двух входов, при
    /// которых машина ставит задачу не по `JobEvent.succeeded` (инвариант 20).
    ///
    /// «Недошедшая» разобрана §8.7 дословно: первая по порядку цепочки, у которой у этой
    /// записи нет НИ успешно завершённой задачи, НИ задачи, ждущей исполнения, НИ идущей.
    /// Три класса задач различает C-013 своими статусами; своего перечисления этот контракт
    /// не заводит (§0, правило о чужих терминах).
    ///
    /// **Два различающих вектора, и они противоположны** (К92): реализация, поставившая
    /// цепочку ЦЕЛИКОМ, и реализация, не поставившая НИЧЕГО, — обе красны.
    func submitFirstUnreached(recordingId: UUID, now: Date) async {
        guard let identifier = store.values.first(where: { $0.recordingId == recordingId })?.sessionId
        else { return }
        let jobs = await jobsOfChain(recordingId: recordingId)
        let reached = Set(
            jobs.filter { $0.status == .succeeded || $0.status == .pending || $0.status == .running }
                .map(\.type)
        )
        guard let next = SessionMachineRules.processingChain.first(where: { !reached.contains($0) })
        else { return }
        guard let payload = await payload(for: next, recordingId: recordingId, session: identifier)
        else { return }
        await submitChain(payload, for: identifier, now: now)
    }

    /// Задачи цепочки §8.7, принадлежащие этой записи, по всем пяти статусам C-013.
    ///
    /// `attribute` РАЗРЕШАЕТСЯ ЧЕРЕЗ ТРАНСКРИПТ, А НЕ ЧЕРЕЗ `recordingId`, и это не обход:
    /// `JobPayload.attribute` несёт `transcriptId` и `meetingId`, а `recordingId` не несёт
    /// вовсе (C-013). Заголовки транскриптов записи даёт C-010 (`headers(recordingId:)`) —
    /// тем же чтением, которым §8.7 берёт `transcriptId` для постановки самой `attribute`.
    /// Второго источника не заводится.
    func jobsOfChain(recordingId: UUID) async -> [Job] {
        let headers = (try? await transcripts.headers(recordingId: recordingId)) ?? []
        let transcriptIds = Set(headers.map(\.id))
        var found: [Job] = []
        for status in [JobStatus.pending, .running, .succeeded, .failed, .cancelled] {
            let batch = (try? await queue.jobs(status: status)) ?? []
            found.append(contentsOf: batch.filter {
                belongs($0.payload, recordingId: recordingId, transcriptIds: transcriptIds)
            })
        }
        return found
    }

    private func belongs(
        _ payload: JobPayload,
        recordingId: UUID,
        transcriptIds: Set<UUID>
    ) -> Bool {
        switch payload {
        case let .transcode(owner):
            return owner == recordingId
        case let .transcribe(owner, _, _):
            return owner == recordingId
        case let .diarize(owner, _):
            return owner == recordingId
        case let .attribute(transcriptId, _):
            return transcriptIds.contains(transcriptId)
        case .summarize:
            // В Срезе 1 не ставится и цепочке не принадлежит (§8.7, К65).
            return false
        }
    }
}
