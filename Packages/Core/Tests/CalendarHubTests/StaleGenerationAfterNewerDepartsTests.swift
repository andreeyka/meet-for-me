//  Продолжение `SyncOneCancellationDefectsTests.swift` — вынесено отдельным файлом той же
//  причиной, что развела его самого от `ControlSurfaceEntryPointsTests.swift`: SwiftLint
//  `file_length`/`type_body_length` считают каждое расширение типа отдельно.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

extension ControlSurfaceEntryPointsTests {

    /// Возврат РП (24.09 21:15 UTC, приёмка #115, п. 2): сценарий, которого
    /// `test_defect_staleGenerationDoesNotWriteSyncOutcome` не покрывал — устаревшее (первое)
    /// поколение доходит до своей записи ПОСЛЕ того, как ВТОРОЕ, более новое поколение УЖЕ
    /// САМО завершилось (тоже отменой) и обнулило `inFlightSync[source]` обратно в `nil`.
    /// Прежний guard (сверка с `inFlightSync[source]`) на этот момент читал бы «источник
    /// пуст, защищать не от кого» — точно так же, как в законном случае «оба вызывающих
    /// отменились, никто не подхватил» (`test_syncOne_cancellingBothCallersCancelsSharedTask`)
    /// — и пропустил бы устаревшую запись НЕПРАВИЛЬНО, поскольку третий (уже завершившийся)
    /// вызывающий на самом деле БЫЛ — просто успел уйти раньше. `lastStartedGeneration[source]`
    /// (никогда не обнуляется) отличает эти два случая: во втором его значение — второе
    /// поколение, не nil.
    ///
    /// Оба поколения отменяются ДО отпуска ворот первого — второе физически не может дойти
    /// до СВОЕГО save (общая цепочка `mergeTail`, инв. 11, тот же довод, что у
    /// `test_defect_newCallerAfterLastWaiterCancelsStartsFreshTaskNotTheCancelledOne`), так что
    /// порядок «оба вызывающих ушли → потом отпускаем первое поколение → потом ждём обе
    /// настоящие задачи» — единственный, которым можно детерминированно застать
    /// `inFlightSync[source] == nil` при живом `lastStartedGeneration[source] == generation
    /// второго` одновременно.
    func test_defect_staleGenerationSuppressedEvenAfterNewerGenerationAlsoLeftInFlightSync() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.setFetchEvents([
            try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: Date())
        ])
        harness.meetingRepository.gate(on: .save)

        let firstTask = Task { await harness.hub.sync(trigger: .manual) }
        await pollUntil { meetingRepositorySaveCallCount(harness.meetingRepository) >= 1 }
        let firstGeneration = await harness.hub.inFlightSync[source]
        let firstGenerationTask = firstGeneration?.task
        XCTAssertNotNil(firstGenerationTask, "первое поколение обязано существовать на этот момент")
        firstTask.cancel()
        let firstResults = await firstTask.value
        XCTAssertEqual(firstResults.first?.failure, .cancelled)
        await pollUntil(timeout: .seconds(2)) { await harness.hub.inFlightSync[source] == nil }

        // Второе поколение заводим и СРАЗУ ЖЕ отменяем тоже — единственный оставшийся
        // ожидающий уходит, inFlightSync[source] обнуляется СНОВА, но lastStartedGeneration
        // (в отличие от inFlightSync) продолжает называть именно его.
        let secondTask = Task { await harness.hub.sync(trigger: .manual) }
        await pollUntil(timeout: .seconds(2)) { await harness.hub.inFlightSync[source] != nil }
        let secondGeneration = await harness.hub.inFlightSync[source]
        let secondGenerationTask = secondGeneration?.task
        XCTAssertNotNil(secondGenerationTask, "второе поколение обязано существовать на этот момент")
        secondTask.cancel()
        let secondResults = await secondTask.value
        XCTAssertEqual(secondResults.first?.failure, .cancelled)
        await pollUntil(timeout: .seconds(2)) { await harness.hub.inFlightSync[source] == nil }

        // Только теперь отпускаем первое (устаревшее) поколение — до этого момента оно всё
        // ещё физически висело на save-воротах, а второе не могло даже дойти до своего save
        // (та же цепочка mergeTail).
        harness.meetingRepository.stopGating(on: .save)
        harness.meetingRepository.release(on: .save)
        _ = await firstGenerationTask?.value
        _ = await secondGenerationTask?.value

        XCTAssertEqual(
            connectorRepositorySetSyncOutcomeCallCount(harness.connectorRepository), 1,
            "устаревшее (первое) поколение обязано остаться подавленным, даже когда inFlightSync " +
                "успел обнулиться уже ПОСЛЕ ухода второго, более нового поколения"
        )
    }
}
