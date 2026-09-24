//  AudioCaptureImpl+HardwareEvents — реакция на события шва. Инварианты 5, 9, 11, 12, 13.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API

import DomainCore
import Foundation

extension AudioCaptureImpl {

    /// Зовётся швом на своей очереди при подписке, оформленной в `buildSession`.
    func handleHardwareEvent(_ event: HardwareEvent) {
        guard case .running(let session) = currentSessionPhase() else { return }
        switch event {
        case .microphoneChanged(let handle, let atHostTime):
            guard case .systemDefault = session.currentInputSelection else { return }
            beginRebuild(session, reason: .rebuild, newMicrophone: handle, atHostTime: atHostTime)
        case .microphoneFormatChanged(let channelCount, let atHostTime):
            let sampleRate = session.request.micFormat.sampleRate
            let oldFormat = TrackFormat(sampleRate: sampleRate,
                                        channelCount: session.currentMicrophoneChannelCount ?? channelCount)
            let newFormat = TrackFormat(sampleRate: sampleRate, channelCount: channelCount)
            session.currentMicrophoneChannelCount = channelCount
            beginRebuild(session, reason: .rebuild, newMicrophone: nil, atHostTime: atHostTime)
            emit(.inputFormatChanged(from: oldFormat, to: newFormat))
        case .tapInvalidated(let atHostTime):
            beginRebuild(session, reason: .sourceGone, newMicrophone: nil, atHostTime: atHostTime)
        case .aggregateDied(let atHostTime):
            beginRebuild(session, reason: .sourceGone, newMicrophone: nil, atHostTime: atHostTime)
        case .processesChanged(let processes, let atHostTime):
            recordProcesses(session, processes: processes, atHostTime: atHostTime)
        }
    }

    /// §«Сон»: источник — `.willSleep`/`.didWake` C-008 (`PowerPort.events()`), не шов
    /// оборудования — контракт называет его дословно. Заведена один раз на жизнь порта (см.
    /// комментарий у `powerEventsTask`), а не на сеанс: `Task.cancel()` не гарантированно
    /// прерывает подвисший `for await` на `AsyncStream`, и пересоздание подписки на каждый
    /// `start()` рисковало бы копить повисшие задачи, державшие `self` сильной ссылкой.
    /// Событие, пришедшее без идущего сеанса, просто отбрасывается проверкой фазы.
    func installPowerEventsIfNeeded() {
        lock.lock()
        let alreadyInstalled = powerEventsInstalled
        powerEventsInstalled = true
        lock.unlock()
        guard !alreadyInstalled else { return }
        powerEventsTask = Task { [weak self] in
            guard let self else { return }
            let stream = self.power.events()
            // Подписка на AsyncStream регистрируется синхронно внутри `events()`, до этой строки —
            // сигнал ниже верен именно в момент, когда `emit` со стороны шва уже не потеряет событие.
            self.markPowerEventsSubscribed()
            for await event in stream {
                // MEE-371 п. 2: будить ожидающих на ЛЮБОЙ развилке итерации, не только на ветке
                // обработки — иначе `performAndAwaitNextPowerEvent` вокруг события, отброшенного
                // проверкой фазы ниже (сеанс не `.running`), висел бы до таймаута теста.
                defer { self.resumePendingPowerEventContinuations() }
                guard case .running(let session) = self.currentSessionPhase() else { continue }
                switch event {
                case .willSleep:
                    self.handleSleep(session, atHostTime: self.currentHostTime(session))
                case .didWake:
                    await self.handleWake(session, atHostTime: self.currentHostTime(session))
                default:
                    break
                }
            }
        }
    }

    /// MEE-371: тест ждёт, пока цикл выше фактически зарегистрирует подписку на `power.events()`
    /// (см. комментарий у `isPowerEventsSubscribed`), вместо фиксированной паузы перед первым
    /// `power.emit(...)`. Если подписка уже установлена (повторный вызов на живом порте — сеансы
    /// разделяют одну подписку на всю жизнь порта), резюмирует немедленно.
    func awaitPowerEventsSubscribed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            powerEventsLock.lock()
            if isPowerEventsSubscribed {
                powerEventsLock.unlock()
                continuation.resume()
                return
            }
            pendingSubscriptionContinuations.append(continuation)
            powerEventsLock.unlock()
        }
    }

    private func markPowerEventsSubscribed() {
        powerEventsLock.lock()
        isPowerEventsSubscribed = true
        let waiting = pendingSubscriptionContinuations
        pendingSubscriptionContinuations = []
        powerEventsLock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    /// MEE-365: тест зовёт `action` (обычно — `power.emit(...)`) и ждёт, пока цикл выше не
    /// обработает СЛЕДУЮЩЕЕ событие C-008 целиком (`handleSleep`/`handleWake`/пропуск) —
    /// вместо фиксированной паузы, угадывающей scheduling-задержку `powerEventsTask`.
    /// Продолжение регистрируется ДО вызова `action`, внутри той же замыкающей области:
    /// событие не может быть обработано раньше, чем ожидающий встанет в очередь.
    func performAndAwaitNextPowerEvent(_ action: () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            powerEventsLock.lock()
            pendingPowerEventContinuations.append(continuation)
            powerEventsLock.unlock()
            action()
        }
    }

    private func resumePendingPowerEventContinuations() {
        powerEventsLock.lock()
        let waiting = pendingPowerEventContinuations
        pendingPowerEventContinuations = []
        powerEventsLock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    private func handleSleep(_ session: CaptureSessionState, atHostTime: UInt64) {
        let atMs = session.referenceTrack?.positionMs ?? 0
        if let marker = try? RecordingManifest.Marker(kind: .sleep, atMs: atMs, detail: nil) {
            session.markers.append(marker)
        }
        // §«Сон»: контракт требует ОБА маркера сразу — `.sleep` и `.discontinuity` — и немедленный
        // сброс буферов на диск, а не отложенные до первого буфера после пробуждения: система
        // может проспать сколь угодно долго, а до пробуждения на диске обязан остаться след
        // случившегося разрыва, а не тишина без объяснения.
        //
        // Возврат MEE-317 (второй круг): маркер `.discontinuity` без парного элемента в
        // `discontinuities` нарушает инвариант 15 C-002 (RecordingManifestValidation) — writeManifest
        // ниже молча проваливался бы (через `try?`), а stop() до пробуждения падал бы вовсе.
        // Значит пара пишется здесь целиком: маркер и предварительный `Discontinuity` с известным
        // на этот момент `fileMinusHostMs` (то же значение, что вычисляет `beginRebuild` для
        // `pendingRebuild`) и `gapMs: 0` — гап ещё не начал накапливаться, сон только что начался.
        // `resolveRebuild` при пробуждении заменяет эту запись точной (см. там же), а не добавляет
        // вторую — иначе на диске остались бы два разрыва на один сон.
        //
        // Возврат MEE-317 (п. 6, MEE-365): `beginRebuild` сам пишет манифест на диск изнутри
        // `recordProcesses` (инв. 12(б)) — раньше это давало ВТОРУЮ, более раннюю запись между
        // маркером `.sleep` выше и парой ниже, с `.sleep` уже на диске, но без пары. Критерий —
        // ближайший К9 (парный маркер и запись разрыва), не отдельная цитата контракта: сама пара
        // писалась правильно, просто существовало наблюдаемое окно с неполным её половиной.
        // `persistManifestAfterCapturedProcesses: false` снимает эту раннюю запись — на диск
        // манифест уходит один раз, ниже, когда пара уже дописана.
        //
        // СТРОКА: возврат MEE-317 (третий круг) — прежде это было непомеченным решением, не
        // вилкой. Если сон пришёл поверх уже идущей пересборки другой причины
        // (`session.pendingRebuild` уже занят), `beginRebuild` ниже не заводит новый
        // `pendingRebuild` (охрана на его первой строке) — и тогда для этого сна не пишется ни
        // маркер `.discontinuity`, ни парный `Discontinuity` (только уже стоящий маркер `.sleep`
        // выше). Контракт требует пару «сразу» на сон, но не говорит явно, что происходит, когда
        // сон застаёт УЖЕ идущую пересборку другой причины. Вилка не решена мной:
        // (а) как сейчас — считать, что сон, наложившийся на чужую пересборку, охвачен разрывом
        //     этой пересборки (тот `Discontinuity`/маркер её причины уже покрывает интервал), и
        //     отдельная пара на сон здесь была бы задвоением на один физический разрыв;
        // (б) сон обязан получать свою пару всегда, независимо от `pendingRebuild` — тогда нужен
        //     отдельный путь записи (не через `beginRebuild`), и один физический интервал мог бы
        //     нести два маркера `.discontinuity` разных причин одновременно. Решение — за РП.
        let hadPendingRebuild = session.pendingRebuild != nil
        beginRebuild(
            session, reason: .sleep, newMicrophone: nil, atHostTime: atHostTime,
            persistManifestAfterCapturedProcesses: false
        )
        if !hadPendingRebuild, let pending = session.pendingRebuild {
            let scaleErrorMs = ScaleError.compute(reason: .sleep, fileMinusHostMs: pending.fileMinusHostMs)
            if let discontinuity = try? RecordingManifest.Discontinuity(
                atMs: pending.atMs, gapMs: 0, scaleErrorMs: scaleErrorMs, reason: .sleep
            ), let marker = try? RecordingManifest.Marker(kind: .discontinuity, atMs: pending.atMs, detail: "sleep") {
                session.discontinuities.append(discontinuity)
                session.markers.append(marker)
            }
        }
        for track in [session.micTrack, session.systemTrack].compactMap({ $0 }) {
            track.flush(atHostTime: atHostTime)
        }
        writeManifest(session, endedAt: nil, isFinalized: false)
    }

    /// «После `.didWake` порт берёт новый токен удержания и продолжает» — дословно контракт:
    /// удержание, взятое до сна, само становится недействительным вместе с сном системы.
    private func handleWake(_ session: CaptureSessionState, atHostTime: UInt64) async {
        let atMs = session.referenceTrack?.positionMs ?? 0
        if let marker = try? RecordingManifest.Marker(kind: .wake, atMs: atMs, detail: nil) {
            session.markers.append(marker)
        }
        session.powerToken?.end()
        session.powerToken = await power.beginActivity(reason: .recording, label: "capture")
        writeManifest(session, endedAt: nil, isFinalized: false)
    }

    /// Инварианты 12—14: состав захвата — объединение снимков за всю запись, не последний снимок.
    /// `containsUnrequested` сравнивает по правилу C-009 §4.1: шаг 1 — appKey процесса,
    /// `responsibleBundleId ?? bundleId` (родитель отвечает за помощника с другим bundle id, тот
    /// же приём, что в `Detector`), шаг 2 — `bundleKeyMatches` (домен, не своё сравнение строк).
    ///
    /// `persistManifest`: MEE-365 (возврат по MEE-317 п. 6) — `beginRebuild` зовёт этот метод
    /// как часть пересборки (инв. 12(б)), и по умолчанию его собственная запись на диск здесь и
    /// остаётся единственной для путей БЕЗ дальнейшего состояния после `beginRebuild`
    /// (`.microphoneChanged`/`.tapInvalidated`/`.aggregateDied`). У `.sleep` (`handleSleep`) есть
    /// код ПОСЛЕ `beginRebuild` (пара `.discontinuity`) — с записью здесь на диске побывало бы
    /// промежуточное состояние: `.sleep`-маркер уже есть, пары ещё нет. `handleSleep` передаёт
    /// `false` и пишет сам, один раз, когда пара уже дописана — К9 требует маркер и пару вместе.
    func recordProcesses(
        _ session: CaptureSessionState, processes: [CaptureProcessDescriptor], atHostTime: UInt64,
        persistManifest: Bool = true
    ) {
        for process in processes { session.recordCapturedProcess(process) }
        let requestedAppKey = session.request.group?.appKey
        let resolvedBundleIds = processes.compactMap(\.bundleId)
        let containsUnrequested: Bool
        if let requestedAppKey {
            containsUnrequested = processes.contains { process in
                let appKey = process.responsibleBundleId ?? process.bundleId
                return appKey != nil && !bundleKeyMatches(appKey: appKey, entry: requestedAppKey)
            }
        } else {
            containsUnrequested = false
        }
        let atMs = session.referenceTrack?.positionMs ?? 0
        let manifestProcesses = processes.compactMap {
            try? RecordingManifest.CapturedProcess(pid: $0.pid, bundleId: $0.bundleId,
                                                   executableName: $0.executableName)
        }
        emit(.capturedProcessesChanged(.init(
            atMs: atMs, observedAt: Date(), requestedAppKey: requestedAppKey,
            resolvedBundleIds: resolvedBundleIds, processes: manifestProcesses, containsUnrequested: containsUnrequested
        )))
        if persistManifest {
            writeManifest(session, endedAt: nil, isFinalized: false)
        }
    }

    private func currentSessionPhase() -> CapturePhase {
        lock.lock(); defer { lock.unlock() }
        return phase
    }

    /// Инвариант 12: не реже `capturedProcessesPollSeconds`, даже без единого события шва.
    func pollCapturedProcesses() {
        guard case .running(let session) = currentSessionPhase(), let tap = session.tap else { return }
        let processes = gateway.capturedProcesses(tap)
        recordProcesses(session, processes: processes, atHostTime: session.hostOrigin)
    }
}
