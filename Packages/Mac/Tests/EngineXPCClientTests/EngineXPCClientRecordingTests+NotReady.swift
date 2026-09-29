//  EngineXPCClientRecordingTests+NotReady — MEE-480, C-012 v12 §1.1 «Отказы» и инв. 24:
//  три причины `recordingNotReady` по одному вектору, в каждом `beginUse` не вызван и запрос
//  не отправлен; бросок репозитория — `serviceUnavailable`.

import XCTest
import DomainCore
import DomainTestKit
import EngineKit
@testable import EngineXPCClient

extension EngineXPCClientRecordingTests {

    /// Общее для каждого вектора отказа по записи: каталог не тронут, транспорт — тоже.
    private func assertNothingReachedModelsOrEngine(
        _ stand: Stand, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(stand.fixture.modelCatalog.beginUseSuccessCount, 0, "beginUse не должен был вызываться",
                       file: file, line: line)
        XCTAssertNil(stand.log.firstIndex(of: Self.resolveCall), "\(stand.log.signatures)", file: file, line: line)
        XCTAssertNil(stand.log.firstIndex(of: Self.beginUseCall), "\(stand.log.signatures)", file: file, line: line)
        XCTAssertEqual(stand.fixture.service.sendCount, 0, "запрос не должен был уйти", file: file, line: line)
        XCTAssertEqual(stand.workRequests.count, 0, file: file, line: line)
    }

    // MARK: - Причина 1: записи нет

    func test_inv24_missingRecordingGivesRecordingNotReadyBeforeModels() async throws {
        let stand = Stand()
        let recordingId = UUID()

        do {
            _ = try await stand.fixture.client.transcribe(makeSpec(recordingId: recordingId)) { _ in }
            XCTFail("ожидался recordingNotReady")
        } catch TranscriptionServiceError.recordingNotReady(let failedId, let message) {
            XCTAssertEqual(failedId, recordingId)
            XCTAssertEqual(message, "записи нет")
        }
        assertNothingReachedModelsOrEngine(stand)
    }

    func test_inv24_embedMissingRecordingGivesRecordingNotReady() async throws {
        let stand = Stand(embeddingModelId: "emb-1")
        let recordingId = UUID()

        do {
            _ = try await stand.fixture.client.embed(recordingId: recordingId, startMs: 0, endMs: 1000, profileId: "p1")
            XCTFail("ожидался recordingNotReady")
        } catch TranscriptionServiceError.recordingNotReady(let failedId, let message) {
            XCTAssertEqual(failedId, recordingId)
            XCTAssertEqual(message, "записи нет")
        }
        assertNothingReachedModelsOrEngine(stand)
    }

    // MARK: - Причина 2: `status != .finalized`

    func test_inv24_recordingStatusGivesRecordingNotReadyWithActualStatus() async throws {
        let stand = Stand()
        let recordingId = UUID()
        stand.recordings.seed([try RecordingFixtures.record(recordingId: recordingId, status: .recording)])

        do {
            _ = try await stand.fixture.client.transcribe(makeSpec(recordingId: recordingId)) { _ in }
            XCTFail("ожидался recordingNotReady")
        } catch TranscriptionServiceError.recordingNotReady(let failedId, let message) {
            XCTAssertEqual(failedId, recordingId)
            XCTAssertTrue(message.contains("recording"), message)
        }
        assertNothingReachedModelsOrEngine(stand)
    }

    /// Остальные значения `RecordingStatus`, кроме `.finalized`, — тот же исход.
    func test_inv24_everyNonFinalizedStatusGivesRecordingNotReady() async throws {
        for status in [RecordingStatus.stopping, .failed] {
            let stand = Stand()
            let recordingId = UUID()
            stand.recordings.seed([try RecordingFixtures.record(recordingId: recordingId, status: status)])

            do {
                _ = try await stand.fixture.client.transcribe(makeSpec(recordingId: recordingId)) { _ in }
                XCTFail("ожидался recordingNotReady для \(status)")
            } catch TranscriptionServiceError.recordingNotReady(_, let message) {
                XCTAssertTrue(message.contains(status.rawValue), message)
            }
            assertNothingReachedModelsOrEngine(stand)
        }
    }

    // MARK: - Причина 3: у `embed` нет дорожки `.system`

    func test_inv24_embedWithoutSystemTrackGivesRecordingNotReady() async throws {
        let stand = Stand(embeddingModelId: "emb-1")
        let recordingId = UUID()
        stand.recordings.seed([
            try RecordingFixtures.record(recordingId: recordingId, tracks: [RecordingFixtures.micTrack()])
        ])

        do {
            _ = try await stand.fixture.client.embed(recordingId: recordingId, startMs: 0, endMs: 1000, profileId: "p1")
            XCTFail("ожидался recordingNotReady")
        } catch TranscriptionServiceError.recordingNotReady(let failedId, let message) {
            XCTAssertEqual(failedId, recordingId)
            XCTAssertEqual(message, "нет дорожки system")
        }
        assertNothingReachedModelsOrEngine(stand)
    }

    // MARK: - Бросок репозитория — не `recordingNotReady`, а `serviceUnavailable`

    func test_inv24_repositoryThrowGivesServiceUnavailable() async throws {
        let stand = Stand()
        let recordingId = UUID()
        stand.recordings.seed([try RecordingFixtures.record(recordingId: recordingId)])
        stand.recordings.fail(
            with: .dataCorrupted(entity: "recording", id: recordingId.uuidString, message: "manifest_json"),
            on: .recordingById
        )

        do {
            _ = try await stand.fixture.client.transcribe(makeSpec(recordingId: recordingId)) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable(let message) {
            XCTAssertTrue(message.contains("manifest_json"), message)
        }
        assertNothingReachedModelsOrEngine(stand)
    }

    func test_inv24_embedRepositoryThrowGivesServiceUnavailable() async throws {
        let stand = Stand(embeddingModelId: "emb-1")
        stand.recordings.fail(with: .io(message: "database is locked"), on: .recordingById)

        do {
            _ = try await stand.fixture.client.embed(recordingId: UUID(), startMs: 0, endMs: 1000, profileId: "p1")
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable {}
        assertNothingReachedModelsOrEngine(stand)
    }
}
