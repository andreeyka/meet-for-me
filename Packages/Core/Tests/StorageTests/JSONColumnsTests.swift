//  JSONColumnsTests — К46 перечня MEE-189 (инвариант 27, граница), владелец: DEV-2.
//
//  К43 (инвариант 27, вектор 1: DomainJSON против стандартного JSONDecoder на
//  `1e400`/дублирующемся ключе/дробном литерале в целом поле, по всем четырём
//  колонкам JSON) сюда не входит — какие именно поля `RecordingManifest`,
//  `Transcript.Word`, `JobPayload` и `[String]` действительно проходят через
//  `decodeBounded`/`decodeFinite` (а не через синтезированный `Codable`, где
//  сам JSONDecoder может смолчать иначе, чем ожидает критерий), не установлено
//  в этой части — находка в отчёте части, не решаю здесь произвольно.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class JSONColumnsTests: StorageAsyncTestCase {

    private static let nonJSONBytes = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF])

    // MARK: - К46(i): connectors.settings_json — байты проезжают не разбираясь

    func testK46i_connectorSettingsJsonPassesThroughUnparsed() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let connectors = temp.database.connectorRepository()
        let record = ConnectorRecord(
            id: "c1", type: "eventkit", pluginId: nil, settingsJson: Self.nonJSONBytes,
            keychainNamespace: "ns", selectedCalendarIds: [], isEnabled: true,
            lastSyncAt: nil, cursor: nil, lastError: nil
        )
        try await connectors.upsert(record)

        let all = try await connectors.all()
        let read = try XCTUnwrap(all.first { $0.id == "c1" })
        XCTAssertEqual(read.settingsJson, Self.nonJSONBytes, "байты доезжают побайтно")
    }

    // MARK: - К46(ii): meeting_outputs.structured_json — байты проезжают не разбираясь

    func testK46ii_meetingOutputStructuredJsonPassesThroughUnparsed() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let meetings = temp.database.meetingRepository()
        let outputs = temp.database.meetingOutputRepository()
        let event = try TestFixtures.meetingEvent()
        try await meetings.save(MeetingRecord(event: event, dedupKey: nil, status: .ready, sources: []))

        let output = MeetingOutput(
            id: UUID(), meetingId: event.id, kind: .summary, engine: "e", modelVersion: "1.0",
            promptVersion: "1.0", contentMarkdown: "# hi", structuredJson: Self.nonJSONBytes,
            createdAt: TestFixtures.epoch, isUserEdited: false
        )
        try await outputs.save(output)

        let saved = try await outputs.outputs(meetingId: event.id)
        let read = try XCTUnwrap(saved.first { $0.id == output.id })
        XCTAssertEqual(read.structuredJson, Self.nonJSONBytes, "байты доезжают побайтно")
    }

    // MARK: - К46(iii): app_settings.value — байты проезжают не разбираясь

    func testK46iii_settingsValuePassesThroughUnparsed() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let settings = temp.database.settingsRepository()
        try await settings.setValue(Self.nonJSONBytes, forKey: "k")

        let read = try await settings.value(forKey: "k")
        XCTAssertEqual(read, Self.nonJSONBytes, "байты доезжают побайтно")
    }

    // MARK: - К46(iv): meetings.dedup_key — dataCorrupted по общему правилу «Ошибки»

    func testK46iv_unparsableDedupKeyGivesDataCorrupted() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let meetings = temp.database.meetingRepository()
        let event = try TestFixtures.meetingEvent()
        try await meetings.save(MeetingRecord(event: event, dedupKey: nil, status: .ready, sources: []))
        try temp.database.rawWrite { db in
            try db.execute(
                sql: "UPDATE meetings SET dedup_key = 'not-json' WHERE id = ?", arguments: [event.id.uuidString]
            )
        }

        do {
            _ = try await meetings.meeting(id: event.id)
            XCTFail("ожидался dataCorrupted")
        } catch let error as StorageError {
            guard case .dataCorrupted(let entity, _, _) = error else {
                XCTFail("ожидался dataCorrupted, получено \(error)"); return
            }
            XCTAssertEqual(entity, "Meeting")
        }
    }
}
