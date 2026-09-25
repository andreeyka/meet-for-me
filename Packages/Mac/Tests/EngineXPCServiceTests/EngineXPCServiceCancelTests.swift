//  EngineXPCServiceCancelTests — MEE-438, инв. 6/7 (C-012 v10 §2): `cancel(jobId)` неизвестного
//  или уже завершённого `jobId` — успешный no-op; настоящая отмена прерывает фейковый движок
//  (кооперативно, через `Task.cancel()`) и присылает `.cancelled(jobId)` ИМЕННО на реплай-
//  замыкание ИСХОДНОГО запроса (не на реплай самой команды `.cancel`, у которой свой,
//  отдельный вызов `send`). Точная граница «в течение 5с» (инв. 7) контрактом и MEE-370 названа
//  «предметом теста реализатора» — не проверяется отдельным таймером здесь, только сам факт,
//  что кооперативная отмена доходит и завершает исходный запрос.
//
//  Через `rawServiceProxy`, в обход `EngineXPCClient`: сам клиент (К27/К28, MEE-431) уже
//  резолвит `.cancelled` СРАЗУ по отправке кадра `cancel`, не дожидаясь настоящего ответа
//  сервиса, — так что понаблюдать за реакцией именно СЕРВИСА можно только минуя эту его
//  оптимизацию.
//
//  Каждое тело обёрнуто `withDeadline` (`TestSupport.swift`, тот же приём, что MEE-374):
//  настоящий `NSXPCConnection` — не управляемое время фейка, и висящий круговой обмен обязан
//  падать `XCTFail` за конечное время, а не вешать CI до её собственного сторожа.

import XCTest
import DomainCore
import EngineKit
@testable import EngineXPCClient

final class EngineXPCServiceCancelTests: XCTestCase {

    /// Не метод экземпляра: тело `withDeadline` — `@Sendable`-замыкание, а `XCTestCase` не
    /// `Sendable` — захват `self` только ради этой чистой функции того не стоил бы.
    private static func makeTranscribeRequest() throws -> (jobId: EngineJobId, request: EngineRequest) {
        let audio = try ServiceFixtures.audioRef()
        let request = try TranscriptionRequest(
            audio: [audio], language: nil, wantWordTimestamps: false,
            asrModel: ServiceFixtures.modelBundle(role: .asr), vadModel: nil
        )
        let jobId = EngineJobId(rawValue: UUID())
        return (jobId, .transcribe(jobId, request))
    }

    // MARK: - Инв. 6: неизвестный jobId — успешный no-op

    func test_cancelUnknownJobIdIsSuccessfulNoOp() async {
        await withDeadline {
            let fixture = RealServiceFixture()
            let (proxy, connection) = fixture.rawServiceProxy()
            defer { connection.invalidate() }

            guard let cancelData = try? EngineWire.encode(EngineRequest.cancel(EngineJobId(rawValue: UUID()))) else {
                return XCTFail("не удалось закодировать cancel")
            }
            let (data, error) = await send(proxy, cancelData)

            XCTAssertNil(data)
            XCTAssertNil(error)
        }
    }

    // MARK: - Инв. 7: настоящая отмена прерывает движок и завершает ИСХОДНЫЙ запрос .cancelled

    func test_genuineCancelStopsFakeEngineAndRepliesCancelledOnOriginalCall() async {
        await withDeadline {
            let fixture = RealServiceFixture()
            fixture.transcription.simulatedWorkNanoseconds = 5_000_000_000   // 5с — заведомо дольше отмены
            let (proxy, connection) = fixture.rawServiceProxy()
            defer { connection.invalidate() }
            guard let (jobId, request) = try? Self.makeTranscribeRequest() else {
                return XCTFail("не удалось построить запрос")
            }
            guard let requestData = try? EngineWire.encode(request) else {
                return XCTFail("не удалось закодировать запрос")
            }

            async let originalReply: (Data?, NSError?) = send(proxy, requestData)
            // Даём исходному запросу время дойти до движка (started-прогресс) прежде, чем
            // отменять — без этого гонка могла бы отменить `Task` до того, как он вообще
            // начал `Task.sleep`.
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let cancelFrameData = try? EngineWire.encode(EngineRequest.cancel(jobId)) else {
                return XCTFail("не удалось закодировать cancel")
            }
            let (cancelData, cancelError) = await send(proxy, cancelFrameData)
            XCTAssertNil(cancelData)
            XCTAssertNil(cancelError)

            let (data, error) = await originalReply
            XCTAssertNil(error)
            guard let data, let reply = try? EngineWire.decode(EngineReply.self, from: data) else {
                return XCTFail("исходный ответ не разобран")
            }
            XCTAssertEqual(reply, .cancelled(jobId))
        }
    }

    /// Инв. 6 (вторая половина): jobId уже завершённого (не только никогда не виденного)
    /// запроса — тоже no-op, не отказ.
    func test_cancelAlreadyFinishedJobIdIsSuccessfulNoOp() async {
        await withDeadline {
            let fixture = RealServiceFixture()
            let (proxy, connection) = fixture.rawServiceProxy()
            defer { connection.invalidate() }
            guard let (jobId, request) = try? Self.makeTranscribeRequest() else {
                return XCTFail("не удалось построить запрос")
            }
            guard let requestData = try? EngineWire.encode(request) else {
                return XCTFail("не удалось закодировать запрос")
            }

            let (data, error) = await send(proxy, requestData)
            XCTAssertNil(error)
            XCTAssertNotNil(data)

            guard let cancelFrameData = try? EngineWire.encode(EngineRequest.cancel(jobId)) else {
                return XCTFail("не удалось закодировать cancel")
            }
            let (cancelData, cancelError) = await send(proxy, cancelFrameData)
            XCTAssertNil(cancelData)
            XCTAssertNil(cancelError)
        }
    }

    /// Желательное из возврата РП (MEE-438, 12:15 UTC): три параллельных задачи, разные `jobId`
    /// на ОДНОМ соединении/движке — `cancel` средней не задевает две другие. Доказывает, что
    /// job-реестр (`EngineXPCRequestHandler.jobs`) изолирует по `jobId`, а не по «текущей
    /// единственной задаче» — тот же класс гонки, что уже правился в самом реестре (регистрация
    /// под общим `lock`, возврат РП 11:50 UTC), только теперь снаружи, наблюдаемо по трём
    /// настоящим круговым обменам одновременно.
    func test_concurrentJobsAreIsolatedByJobIdCancellingOneLeavesOthersUnaffected() async {
        await withDeadline(10) {
            let fixture = RealServiceFixture()
            fixture.transcription.simulatedWorkNanoseconds = 1_000_000_000   // 1с — время отменить среднюю
            let (proxy, connection) = fixture.rawServiceProxy()
            defer { connection.invalidate() }

            var requests: [(jobId: EngineJobId, data: Data)] = []
            for _ in 0..<3 {
                guard let (jobId, request) = try? Self.makeTranscribeRequest(),
                      let data = try? EngineWire.encode(request)
                else { return XCTFail("не удалось построить запрос") }
                requests.append((jobId, data))
            }

            async let reply0 = send(proxy, requests[0].data)
            async let reply1 = send(proxy, requests[1].data)
            async let reply2 = send(proxy, requests[2].data)
            // Даём всем трём дойти до движка (см. довод выше про started-прогресс) прежде, чем
            // отменять только среднюю.
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let cancelData = try? EngineWire.encode(EngineRequest.cancel(requests[1].jobId)) else {
                return XCTFail("не удалось закодировать cancel")
            }
            _ = await send(proxy, cancelData)

            let (data0, error0) = await reply0
            let (data1, error1) = await reply1
            let (data2, error2) = await reply2
            XCTAssertNil(error0); XCTAssertNil(error1); XCTAssertNil(error2)
            guard let data0, let decoded0 = try? EngineWire.decode(EngineReply.self, from: data0),
                  let data1, let decoded1 = try? EngineWire.decode(EngineReply.self, from: data1),
                  let data2, let decoded2 = try? EngineWire.decode(EngineReply.self, from: data2)
            else { return XCTFail("ответы не разобраны") }

            XCTAssertEqual(decoded1, .cancelled(requests[1].jobId), "средняя задача обязана быть отменена")
            guard case .transcript(let jobId0, _) = decoded0, case .transcript(let jobId2, _) = decoded2 else {
                return XCTFail("крайние задачи обязаны завершиться транскриптом, получено \(decoded0), \(decoded2)")
            }
            XCTAssertEqual(jobId0, requests[0].jobId)
            XCTAssertEqual(jobId2, requests[2].jobId)
        }
    }
}
