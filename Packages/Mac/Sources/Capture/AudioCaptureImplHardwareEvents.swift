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
        case .microphoneFormatChanged(_, let atHostTime):
            beginRebuild(session, reason: .rebuild, newMicrophone: nil, atHostTime: atHostTime)
            emit(.inputFormatChanged(from: session.request.micFormat, to: session.request.micFormat))
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
            for await event in self.power.events() {
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

    private func handleSleep(_ session: CaptureSessionState, atHostTime: UInt64) {
        let atMs = session.referenceTrack?.positionMs ?? 0
        if let marker = try? RecordingManifest.Marker(kind: .sleep, atMs: atMs, detail: nil) {
            session.markers.append(marker)
        }
        // §«Сон»: контракт требует ОБА маркера сразу — `.sleep` и `.discontinuity` — и немедленный
        // сброс буферов на диск, а не отложенные до первого буфера после пробуждения: система
        // может проспать сколь угодно долго, а до пробуждения на диске обязан остаться след
        // случившегося разрыва, а не тишина без объяснения. Точную запись `Discontinuity` (с
        // посчитанным `gapMs`) по-прежнему делает `resolveRebuild` при пробуждении — раньше её
        // посчитать не из чего (см. там же — маркер для `reason == .sleep` не дублируется).
        if let marker = try? RecordingManifest.Marker(kind: .discontinuity, atMs: atMs, detail: "sleep") {
            session.markers.append(marker)
        }
        for track in [session.micTrack, session.systemTrack].compactMap({ $0 }) {
            track.flush(atHostTime: atHostTime)
        }
        writeManifest(session, endedAt: nil, isFinalized: false)
        beginRebuild(session, reason: .sleep, newMicrophone: nil, atHostTime: atHostTime)
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
    func recordProcesses(
        _ session: CaptureSessionState, processes: [CaptureProcessDescriptor], atHostTime: UInt64
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
        writeManifest(session, endedAt: nil, isFinalized: false)
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
