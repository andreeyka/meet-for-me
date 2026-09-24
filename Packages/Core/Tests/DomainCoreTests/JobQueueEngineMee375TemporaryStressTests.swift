//  MEE-375, временная нагрузочная проверка — снимается перед приёмкой (тем же приёмом, что
//  `test_mee363_temporary_k67RepeatedFiftyTimes` перед приёмкой MEE-363: файл целиком, а не
//  метод в `JobQueueEngineCancelEventsTests.swift`, чтобы не поднять её `type_body_length`
//  за 250 строк без комментариев/пустых — тот же довод, что уже развёл `JobQueueEngineReview
//  .swift`/`Lifecycle.swift`, здесь применён к тестовому файлу).
//
//  РП на приёмке #93 дважды видел зависание на 300 с (лимит MEE-329) на ОБЕИХ работах CI, в
//  местах, не относящихся к диффу MEE-375 (InMemoryTranscriptRepositoryTests, DetectorTests,
//  IntegerReadingTests — три разных, друг с другом не связанных места за два прогона). Каждая
//  ветка выхода `performRevisitSweep()`/`fulfillRequestedRevisitSweep()`/`runRevisitPass()`
//  перепроверена вручную (компилятора на этой машине нет) — на каждый `+= 1` нашёлся свой
//  `-= 1`. Найденный и уже исправленный корень — `FakePowerPort.events()`, не дождавшийся
//  `finishEvents()`, вешает `for await` НАВСЕГДА (см. `FakePowerPort.swift`, `deinit`).
//  Аудит MEE-377 добавил вторую, независимую причину того же симптома «зависание вместо
//  падения»: `iterator.next()` без дедлайна на той же `AsyncStream` — см. `nextOrFail`
//  (`JobQueueEngineTestSupport.swift`), которым этот тест теперь тоже пользуется вместо
//  голого `next()`.
//
//  Этот тест гоняет ровно сценарий
//  `test_mee375_stopClearsPendingRevisitRequestSoNextStartDoesNotDoubleBlock` 50 раз подряд
//  со свежим `rig` на каждом повторе: недетерминированная гонка/утечка счётчика уронила бы
//  один из 50 (или упала бы `XCTFail` от `nextOrFail`, а не зависла) — 50 быстрых зелёных
//  повторов эту гипотезу закрывают для НОВОГО кода этой правки.

import XCTest
@testable import DomainCore
import DomainTestKit

final class JobQueueEngineMee375TemporaryStressTests: XCTestCase {

    func test_mee375_temporary_stopClearsPendingRevisitRequestRepeatedFiftyTimes() async throws {
        for iteration in 0..<50 {
            let rig = JobQueueTestRig()
            // Подписка ДО submit() — см. довод в test_mee375_stopClearsPendingRevisitRequest
            // SoNextStartDoesNotDoubleBlock (JobQueueEngineCancelEventsTests.swift): найденный
            // РП на приёмке #93 корень был именно в обратном порядке здесь.
            let stream = rig.queue.events()
            let iterator = stream.makeAsyncIterator()
            let summarizeId = try await rig.queue.submit(makeSubmission(
                payload: .summarize(meetingId: UUID(), transcriptId: UUID(), profileId: "p")
            ))
            _ = await nextOrFail(iterator)   // submitted — не предмет этого теста

            await rig.queue.start()
            _ = await nextOrFail(iterator)   // blocked(.noHandler) обычного захода
            await rig.queue.stop()

            await rig.queue.performRevisitSweepForTest(withPendingRequest: true)
            let stillRequested = await rig.queue.revisitPassRequested
            XCTAssertFalse(stillRequested, "повтор \(iteration): заявка обязана сняться")

            await rig.queue.start()
            let afterRestart = await nextOrFail(iterator)
            XCTAssertEqual(
                afterRestart, .blocked(jobId: summarizeId, type: .summarize, reason: .noHandler),
                "повтор \(iteration): ровно один blocked, не два"
            )
            await rig.queue.waitUntilIdle()
            await rig.queue.stop()
        }
    }
}
