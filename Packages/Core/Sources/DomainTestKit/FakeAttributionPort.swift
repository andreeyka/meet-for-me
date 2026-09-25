//  FakeAttributionPort — реализация `AttributionPort` в памяти, C-015 (MEE-23) v9
//  §«Фейк для тестов», дословно: тест задаёт готовый `AttributionResult`, который вернёт
//  любой из трёх методов, задаёт ошибку, которую бросит любой из них, и считает вызовы
//  с их аргументами. Позволяет `domain-core` проверить обработчик задачи `attribute` и
//  `app-ui` собрать экран спикеров, не дожидаясь модуля `attribution` (MEE-399).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  Один `forcedError`/`forcedResult` на все три метода — контракт называет отказ
//  «который бросит любой из трёх», не по методу отдельно: тест, проверяющий один метод,
//  настраивает один переключатель.
//
//  `@unchecked Sendable` с замком, а не актор — тот же довод, что у соседних фейков портов:
//  `AttributionPort` объявлен `: Sendable`, и вызовы фейка идут из разных задач очереди/UI.

import Foundation
import DomainCore

public final class FakeAttributionPort: AttributionPort, @unchecked Sendable {

    private let lock = NSLock()

    /// Заданная тестом ошибка — бросается из любого метода раньше `forcedResult`.
    public var forcedError: AttributionError?

    /// Заданный тестом результат успеха. Умолчания нет намеренно (тот же приём, что у
    /// `FakePowerPort(snapshot:)`): вызов без настройки — `preconditionFailure`, а не
    /// подделка результата, который тест не просил.
    public var forcedResult: AttributionResult?

    /// Режим «инв. 8» (C-015, MEE-420, приёмка `8328dd7c`) — выключен по умолчанию, старые
    /// тесты не меняются. Включённый режим перед возвратом `forcedResult` отфильтровывает из
    /// `segmentUpdates` элементы, чей `segmentId` есть во входном `userEditedSegmentIds`
    /// фактического вызова — то, что обязан делать честный порт по инв. 8, но чего этот фейк
    /// структурно не проверяет, когда режим выключен (`forcedResult` тогда отдаётся как есть).
    public var appliesInvariant8 = false

    private var attributeCalls = 0
    private var confirmCalls = 0
    private var rejectCalls = 0

    private var lastAttributeInput: AttributionInput?
    private var lastAttributeThresholds: AttributionThresholds?
    private var lastConfirmTranscriptId: UUID?
    private var lastConfirmCluster: Int?
    private var lastConfirmPersonId: UUID?
    private var lastConfirmInput: AttributionInput?
    private var lastRejectTranscriptId: UUID?
    private var lastRejectCluster: Int?
    private var lastRejectInput: AttributionInput?

    public init() {}

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public func attribute(
        _ input: AttributionInput,
        thresholds: AttributionThresholds
    ) async throws -> AttributionResult {
        locked {
            attributeCalls += 1
            lastAttributeInput = input
            lastAttributeThresholds = thresholds
        }
        return try result(input: input)
    }

    public func confirm(
        transcriptId: UUID,
        cluster: Int,
        personId: UUID,
        input: AttributionInput
    ) async throws -> AttributionResult {
        locked {
            confirmCalls += 1
            lastConfirmTranscriptId = transcriptId
            lastConfirmCluster = cluster
            lastConfirmPersonId = personId
            lastConfirmInput = input
        }
        return try result(input: input)
    }

    public func reject(
        transcriptId: UUID,
        cluster: Int,
        input: AttributionInput
    ) async throws -> AttributionResult {
        locked {
            rejectCalls += 1
            lastRejectTranscriptId = transcriptId
            lastRejectCluster = cluster
            lastRejectInput = input
        }
        return try result(input: input)
    }

    private func result(input: AttributionInput) throws -> AttributionResult {
        if let forcedError = locked({ forcedError }) { throw forcedError }
        guard let forcedResult = locked({ forcedResult }) else {
            preconditionFailure("тест обязан задать forcedResult до вызова attribute/confirm/reject")
        }
        guard locked({ appliesInvariant8 }) else { return forcedResult }
        let excluded = Set(input.userEditedSegmentIds)
        return AttributionResult(
            transcriptId: forcedResult.transcriptId,
            assignments: forcedResult.assignments,
            segmentUpdates: forcedResult.segmentUpdates.filter { !excluded.contains($0.segmentId) },
            textCorrections: forcedResult.textCorrections,
            profileUpdates: forcedResult.profileUpdates
        )
    }

    // MARK: - Наблюдаемость: считает вызовы с их аргументами (§«Фейк для тестов»)

    public var attributeCallCount: Int { locked { attributeCalls } }
    public var confirmCallCount: Int { locked { confirmCalls } }
    public var rejectCallCount: Int { locked { rejectCalls } }

    public var lastAttributedInput: AttributionInput? { locked { lastAttributeInput } }
    public var lastAttributedThresholds: AttributionThresholds? { locked { lastAttributeThresholds } }

    public var lastConfirmedTranscriptId: UUID? { locked { lastConfirmTranscriptId } }
    public var lastConfirmedCluster: Int? { locked { lastConfirmCluster } }
    public var lastConfirmedPersonId: UUID? { locked { lastConfirmPersonId } }
    public var lastConfirmedInput: AttributionInput? { locked { lastConfirmInput } }

    public var lastRejectedTranscriptId: UUID? { locked { lastRejectTranscriptId } }
    public var lastRejectedCluster: Int? { locked { lastRejectCluster } }
    public var lastRejectedInput: AttributionInput? { locked { lastRejectInput } }
}
