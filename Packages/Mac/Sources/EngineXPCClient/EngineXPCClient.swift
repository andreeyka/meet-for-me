//  EngineXPCClient — реализация `TranscriptionServicePort` (C-012 v13 §1) поверх
//  `NSXPCConnection` (§3). Владеет соединением (§«Данные на границе»: «Соединением
//  NSXPCConnection владеет EngineXPCClient») и распиской каталога моделей вокруг каждого
//  обращения к движку (§«Поведение»: «Тот же адаптер берёт и гасит расписку»).
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (клиент NSXPCConnection)
//
//  СОЕДИНЕНИЕ — ЛЕНИВОЕ И ПЕРЕСОЗДАВАЕМОЕ (§«Поведение»: «Соединение создаётся лениво при
//  первом запросе»; К30). `makeConnection` — фабрика, а не хранимое значение: `interruptionHandler`
//  метит текущее соединение мёртвым, следующий запрос вызывает фабрику заново. В проде это
//  `NSXPCConnection(serviceName:)` — встроенный сервис приложения (C-012 v10 §3:
//  `Contents/XPCServices/TranscriptionEngine.xpc`, имя `<bundle-id>.TranscriptionEngine`;
//  система поднимает его по требованию); в тестах —
//  замыкание над `NSXPCListener.anonymous().endpoint`, тем же приёмом создающее новое
//  соединение к тому же слушателю на каждый вызов.
//
//  ДВА ТАЙМАУТА (§«Поведение»: «Таймауты»; К38). Рабочий запрос без прогресса и без ответа
//  дольше 120с → `timedOut(120)`, отсчёт сбрасывается каждым сообщением прогресса; `ping` —
//  10с, без сброса (ему нечем его сбрасывать — прогресса у `ping` не бывает). Часы —
//  инжектируемое замыкание конструктора (тот же приём, что `SystemClock`/`ManualClock`),
//  сторож — реальный `Task.sleep` на короткий интервал опроса, который сравнивает инжектируемое
//  «сейчас» с моментом последней активности: тест продвигает часы мгновенно, сторож замечает
//  это на ближайшем тике опроса, не дожидаясь настоящих 120 секунд.
//
//  ОТМЕНА (К27, К28). `Task.cancel()` во время ожидания — client сам отправляет кадр
//  `.cancel(jobId)` (счётчик отправок транспорта растёт) и бросает `.cancelled` НЕ дожидаясь
//  финального `EngineReply` того же `jobId`; если ответ (обычный или `.cancelled`) всё же
//  придёт позже — резолюция уже занята, второй резолв — no-op (тот же приём решает и гонку
//  К27: кто раньше — реальный ответ или отмена, — тот и определяет исход).
//
//  МОДЕЛИ (К46, К53). `resolve(profileId:)` → `beginUse(бандлы)` → отправка запроса движку →
//  `endUse(расписка)` — дословный порядок контракта. Отказ `resolve`/`beginUse` — `modelsNotReady`,
//  запрос движку при этом не уходит вовсе (счётчик отправок транспорта не растёт).
//
//  ОТМЕНА ДО ОТПРАВКИ (C-012 v13 §3.2, строка «`CancellationError`, брошенный
//  `RecordingRepository.recording(id:)`, `resolve(profileId:)` или `beginUse(_:)` до отправки
//  запроса»; инв. 12; IR-154 п. 2, MEE-510). `CancellationError` из любого из трёх портов —
//  `cancelled`, а не `serviceUnavailable`/`modelsNotReady`: запрос не отправлен, `cancel(jobId)`
//  слать нечего, `endUse` без выданной расписки не зовётся. Правило — по ТИПУ ошибки, не по
//  `Task.isCancelled`; `ModelCatalogError.cancelled` (C-014) — по-прежнему `modelsNotReady`.
//
//  ЗАПИСЬ И ДОРОЖКИ (C-012 v12 §1.1, инв. 24–26; MEE-480). До каталога моделей — один вызов
//  `RecordingRepository.recording(id:)`; пригодна запись, которая есть и у которой
//  `status == .finalized` (`manifest.isFinalized` не читается — v12). Отказы по записи —
//  `recordingNotReady`, до `resolve`/`beginUse`; бросок репозитория — `serviceUnavailable`
//  (последняя строка §3.2), кроме `CancellationError` — `cancelled` (v13 §3.2). `AudioRef` — по одной на каждую `Track` манифеста, `offsetMs == 0`.
//  `.diarize` адаптер не отправляет (инв. 26): `diarizeSystemChannel` в срезе 1 не читается.

import Foundation
import DomainCore
import EngineKit

public final class EngineXPCClient: TranscriptionServicePort, @unchecked Sendable {

    static let pingTimeoutSeconds = 10
    static let workTimeoutSeconds = 120
    // Не `private` — методы соединения/кругового обмена читают эти члены из
    // `EngineXPCClient+Transport.swift`; `private` в Swift ограничен ФАЙЛОМ объявления, не
    // типом, и был бы недоступен оттуда (тот же приём, что у хранимых свойств `AppFacadeImpl`,
    // читаемых из `AppFacadeImpl+*.swift`).
    static let watchdogPollNanoseconds: UInt64 = 20_000_000   // 20мс

    let makeConnection: @Sendable () -> NSXPCConnection
    private let modelCatalog: ModelCatalogPort
    private let recordings: RecordingRepository
    private let fileLayout: FileLayout
    let clock: @Sendable () -> Date

    let lock = NSLock()
    var connection: NSXPCConnection?
    var jobs: [EngineJobId: PendingJob] = [:]
    /// К21: привязано к КОНКРЕТНОМУ соединению (`ObjectIdentifier`, не голый `Bool`) —
    /// возврат РП по MEE-431 (09:40 UTC): плоский флаг решала гонка с `connectionDied` —
    /// успешный `pong`, дошедший ПОСЛЕ того, как то же соединение уже умерло и было
    /// заменено новым, мог бы выставить флаг для НОВОГО (на деле непроверенного)
    /// соединения. Сброшен `connectionDied` в `nil`; `markHandshakeVerifiedIfMatchingPong`
    /// (`EngineXPCClient+Transport.swift`) пишет только по факту разбора настоящего `.pong`,
    /// то есть только для соединения, на котором тот реально пришёл.
    var handshakeVerifiedConnection: ObjectIdentifier?

    /// Прод: соединение со встроенным XPC-сервисом приложения по его имени (C-012 v10 §3:
    /// `<bundle-id>.TranscriptionEngine`, бандл в `Contents/XPCServices/`) —
    /// `NSXPCConnection(serviceName:)`. Реальный `EngineXPCServiceProtocol` раздаёт сервис
    /// (`Services/TranscriptionEngineXPC`), эта сторона его не знает — только протокол.
    /// Без параметра часов — реальные часы нужны только тестам (внутренний
    /// `init(makeConnection:modelCatalog:clock:)`), и вынесение `Date` в публичную сигнатуру
    /// раздувало бы поверхность модуля типом, которого нет в `allowed-types/EngineXPCClient.json`.
    ///
    /// MEE-471: прежний вход `init(machServiceName:modelCatalog:)` (служба launchd) убран —
    /// контракт кладёт сервис только в `XPCServices`, вызывающих у входа не было ни одного, а
    /// второй публичный путь соединения, который никто не собирает, — непроверяемая поверхность.
    ///
    /// MEE-480 (C-012 v12 §1.1): `recordings` и `fileLayout` — те же, что получает фасад
    /// (C-016): путь к дорожке строится той же формулой, что `AudioTrackRef.fileURL`.
    public convenience init(
        serviceName: String,
        modelCatalog: ModelCatalogPort,
        recordings: RecordingRepository,
        fileLayout: FileLayout
    ) {
        self.init(
            makeConnection: { NSXPCConnection(serviceName: serviceName) },
            modelCatalog: modelCatalog,
            recordings: recordings,
            fileLayout: fileLayout,
            clock: { Date() }
        )
    }

    /// Тесты (`@testable import`): фабрика соединения — обычно замыкание над
    /// `NSXPCListener.anonymous().endpoint`, вызывается заново на каждое пересоздание.
    init(
        makeConnection: @escaping @Sendable () -> NSXPCConnection,
        modelCatalog: ModelCatalogPort,
        recordings: RecordingRepository,
        fileLayout: FileLayout,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.makeConnection = makeConnection
        self.modelCatalog = modelCatalog
        self.recordings = recordings
        self.fileLayout = fileLayout
        self.clock = clock
    }

    func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: - TranscriptionServicePort

    public func ping() async throws -> String {
        let reply = try await roundTrip(.ping, timeoutSeconds: Self.pingTimeoutSeconds, progress: nil)
        guard case .pong(let serviceVersion, let serviceProtocolVersion) = reply else {
            throw TranscriptionServiceError.serviceUnavailable(message: "неожиданный ответ на ping: \(reply)")
        }
        try requireMatchingProtocolVersion(serviceProtocolVersion: serviceProtocolVersion)
        // Рукопожатие уже помечено `complete(jobId:replyData:error:)` в момент разбора
        // ЭТОГО `.pong` — см. заголовок `markHandshakeVerifiedIfMatchingPong` в
        // `EngineXPCClient+Transport.swift`: та точка знает АКТУАЛЬНОЕ соединение без
        // риска создать новое только чтобы зафиксировать его «на старте» (K21 — один раз
        // на соединение, а не один раз на вызов `ping`).
        return serviceVersion
    }

    public func transcribe(
        _ spec: TranscriptionJobSpec,
        progress: @Sendable @escaping (TranscriptionProgress) -> Void
    ) async throws -> Transcript {
        // C-012 v12 §1.1: запись — раньше каталога моделей (инв. 24).
        let manifest = try await readyManifest(recordingId: spec.recordingId)
        let profile = try await resolveProfile(spec.profileId)
        var bundles = [profile.asr]
        if let vad = profile.vad { bundles.append(vad) }
        return try await withModelUse(profileId: spec.profileId, bundles) {
            let request = try Self.buildRequest {
                let audio = try manifest.tracks.map { try self.audioRef(for: $0, of: manifest) }
                return try TranscriptionRequest(
                    audio: audio, language: spec.language, wantWordTimestamps: spec.wantWordTimestamps,
                    asrModel: profile.asr, vadModel: profile.vad
                )
            }
            let jobId = EngineJobId(rawValue: UUID())
            let reply = try await roundTrip(
                .transcribe(jobId, request), timeoutSeconds: Self.workTimeoutSeconds, progress: progress
            )
            return try Self.transcript(from: reply, expectedJobId: jobId)
        }
    }

    public func embed(recordingId: UUID, startMs: Int, endMs: Int, profileId: String) async throws -> [Float] {
        // C-012 v12 §1.1: `embed` берёт дорожку `.system`; её отсутствие — третья причина
        // `recordingNotReady`, и она тоже до каталога моделей.
        let manifest = try await readyManifest(recordingId: recordingId)
        guard let systemTrack = manifest.tracks.first(where: { $0.channel == .system }) else {
            throw TranscriptionServiceError.recordingNotReady(
                recordingId: recordingId, message: "нет дорожки system"
            )
        }
        let profile = try await resolveProfile(profileId)
        guard let embeddingModel = profile.embedding else {
            throw TranscriptionServiceError.modelsNotReady(
                profileId: profileId, message: "профиль не называет модель эмбеддингов"
            )
        }
        return try await withModelUse(profileId: profileId, [embeddingModel]) {
            let request = try Self.buildRequest {
                let audio = try self.audioRef(for: systemTrack, of: manifest)
                let slice = try AudioSlice(source: audio, startMs: startMs, endMs: endMs)
                return try EmbeddingRequest(slice: slice, model: embeddingModel)
            }
            let jobId = EngineJobId(rawValue: UUID())
            let reply = try await roundTrip(
                .embed(jobId, request), timeoutSeconds: Self.workTimeoutSeconds, progress: nil
            )
            return try Self.embeddingVector(from: reply, expectedJobId: jobId)
        }
    }

    // MARK: - Модели (§«Поведение», К46, К53)

    private func resolveProfile(_ profileId: String) async throws -> ResolvedProfile {
        do {
            return try await modelCatalog.resolve(profileId: profileId)
        } catch is CancellationError {
            // C-012 v13 §3.2, строка «`CancellationError` … до отправки запроса».
            throw TranscriptionServiceError.cancelled
        } catch {
            throw TranscriptionServiceError.modelsNotReady(profileId: profileId, message: "\(error)")
        }
    }

    /// `resolve`/`beginUse` до отправки запроса движку (К46: счётчик отправок транспорта
    /// не растёт при отказе любого из двух); `endUse` в `defer`-эквиваленте — на успехе,
    /// отказе и отмене `Task` одинаково (К53). `profileId` — отдельным параметром, а не из
    /// `bundles.first?.modelId`: это ID МОДЕЛИ (например, «asr-1»), не ID профиля («p1»),
    /// который обязан нести `modelsNotReady` — тот же профиль, что назвал вызывающий.
    private func withModelUse<Value>(
        profileId: String, _ bundles: [ModelBundle], _ body: () async throws -> Value
    ) async throws -> Value {
        let token: ModelUseToken
        do {
            token = try await modelCatalog.beginUse(bundles)
        } catch is CancellationError {
            // C-012 v13 §3.2: расписки нет — `endUse` гасить нечего, запрос не уходит.
            throw TranscriptionServiceError.cancelled
        } catch {
            throw TranscriptionServiceError.modelsNotReady(profileId: profileId, message: "\(error)")
        }
        do {
            let value = try await body()
            await modelCatalog.endUse(token)
            return value
        } catch {
            await modelCatalog.endUse(token)
            throw error
        }
    }

    /// Тотальность инв. 11: `TranscriptionRequest`/`AudioSlice`/`EmbeddingRequest`/`AudioRef` —
    /// все throwing-конструкторы C-011, и `DomainValidationError` из них раньше уходил наружу
    /// как есть, нарушая тотальность порта (`TranscriptionServicePort` обязан бросать только
    /// `TranscriptionServiceError`). Возврат РП по MEE-431 (10:27 UTC): НЕ `invalidRequest` —
    /// по таблице §3.2 этот случай зарезервирован за отказами САМОГО СЕРВИСА (код 3 и код вне
    /// 1…3), а не за тем, что реализация порта не прошла собственную проверку до всякого
    /// обращения к транспорту. `serviceUnavailable` — тот же случай, что и отказ кодирования
    /// запроса (`encode(_:)` в `EngineXPCClient+Transport.swift`) чуть ниже по стеку.
    private static func buildRequest<Value>(_ body: () throws -> Value) throws -> Value {
        do {
            return try body()
        } catch let validationError as DomainValidationError {
            throw TranscriptionServiceError.serviceUnavailable(message: "\(validationError)")
        }
    }

    // MARK: - Запись и дорожки (C-012 v12 §1.1, инв. 24, 25)

    /// Единственное обращение к `RecordingRepository` (инв. 24). Пригодна запись, которая
    /// есть и у которой `status == .finalized`; `manifest.isFinalized` не читается (v12).
    private func readyManifest(recordingId: UUID) async throws -> RecordingManifest {
        let record: RecordingRecord?
        do {
            record = try await recordings.recording(id: recordingId)
        } catch is CancellationError {
            // C-012 v13 §3.2, строка «`CancellationError`, брошенный
            // `RecordingRepository.recording(id:)` … до отправки запроса» — `cancelled`.
            throw TranscriptionServiceError.cancelled
        } catch {
            // C-012 v13 §1.1, строка «`recording(id:)` бросил»: не `recordingNotReady`, а
            // последняя строка §3.2 («любая другая ошибка … кроме `CancellationError`»).
            throw TranscriptionServiceError.serviceUnavailable(message: "recording(id:): \(error)")
        }
        guard let record else {
            throw TranscriptionServiceError.recordingNotReady(recordingId: recordingId, message: "записи нет")
        }
        guard record.status == .finalized else {
            throw TranscriptionServiceError.recordingNotReady(
                recordingId: recordingId, message: "status = \(record.status.rawValue)"
            )
        }
        return record.manifest
    }

    /// Инв. 25: поля — из манифеста и `Track` как есть; путь — формулой
    /// `AudioTrackRef.fileURL` (C-016 §1); `offsetMs == 0` всегда (§1.1, «Почему ноль»).
    private func audioRef(for track: RecordingManifest.Track, of manifest: RecordingManifest) throws -> AudioRef {
        try AudioRef(
            recordingId: manifest.recordingId,
            channel: track.channel,
            fileURL: fileLayout.recordingDirectory(manifest.directoryName).appendingPathComponent(track.fileName),
            sampleRate: track.sampleRate,
            channelCount: track.channelCount,
            offsetMs: 0
        )
    }

    private static func transcript(from reply: EngineReply, expectedJobId: EngineJobId) throws -> Transcript {
        switch reply {
        case .transcript(let jobId, let transcript) where jobId == expectedJobId:
            return transcript
        default:
            throw outcome(for: reply, expectedJobId: expectedJobId)
        }
    }

    private static func embeddingVector(from reply: EngineReply, expectedJobId: EngineJobId) throws -> [Float] {
        switch reply {
        case .embedding(let jobId, let result) where jobId == expectedJobId:
            return result.vector
        default:
            throw outcome(for: reply, expectedJobId: expectedJobId)
        }
    }
}
