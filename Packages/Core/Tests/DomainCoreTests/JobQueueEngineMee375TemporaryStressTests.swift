//  MEE-375, временная нагрузочная проверка — снимается перед приёмкой (тем же приёмом, что
//  `test_mee363_temporary_k67RepeatedFiftyTimes` перед приёмкой MEE-363: файл целиком, а не
//  метод в `JobQueueEngineCancelEventsTests.swift`, чтобы не поднять её `type_body_length`
//  за 250 строк без комментариев/пустых — тот же довод, что уже развёл `JobQueueEngineReview
//  .swift`/`Lifecycle.swift`, здесь применён к тестовому файлу).
//
//  РП на приёмке #93 (прогон 36012909776) увидел зависание на 300 с (лимит MEE-329) на ОБОИХ
//  работах CI, в местах, не относящихся к диффу MEE-375, и предположил незакрытое
//  обязательство `activeRevisitPasses`/`isRevisitLoopRunning` после правки «снять
//  revisitPassRequested до проверки isRunning» (`JobQueueEngineReview.swift`). Каждая ветка
//  выхода `performRevisitSweep()`/`fulfillRequestedRevisitSweep()`/`runRevisitPass()`
//  перепроверена вручную (компилятора на этой машине нет) — на каждый `+= 1` нашёлся свой
//  `-= 1` (`defer` либо парная ветка `guard`). Этот тест гоняет ровно сценарий
//  `test_mee375_stopClearsPendingRevisitRequestSoNextStartDoesNotDoubleBlock` 50 раз подряд
//  со свежим `rig` на каждом повторе: недетерминированная гонка/утечка счётчика уронила бы
//  один из 50 либо привела бы к зависанию самого шага — 50 быстрых зелёных повторов эту
//  гипотезу закрывают для НОВОГО кода этой правки.

import XCTest
@testable import DomainCore
import DomainTestKit

final class JobQueueEngineMee375TemporaryStressTests: XCTestCase {

    func test_mee375_temporary_stopClearsPendingRevisitRequestRepeatedFiftyTimes() async throws {
        for iteration in 0..<50 {
            let rig = JobQueueTestRig()
            let summarizeId = try await rig.queue.submit(makeSubmission(
                payload: .summarize(meetingId: UUID(), transcriptId: UUID(), profileId: "p")
            ))
            let stream = rig.queue.events()
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()   // submitted — не предмет этого теста

            await rig.queue.start()
            _ = await iterator.next()   // blocked(.noHandler) обычного захода
            await rig.queue.stop()

            await rig.queue.performRevisitSweepForTest(withPendingRequest: true)
            let stillRequested = await rig.queue.revisitPassRequested
            XCTAssertFalse(stillRequested, "повтор \(iteration): заявка обязана сняться")

            await rig.queue.start()
            let afterRestart = await iterator.next()
            XCTAssertEqual(
                afterRestart, .blocked(jobId: summarizeId, type: .summarize, reason: .noHandler),
                "повтор \(iteration): ровно один blocked, не два"
            )
            await rig.queue.waitUntilIdle()
            await rig.queue.stop()
        }
    }
}
