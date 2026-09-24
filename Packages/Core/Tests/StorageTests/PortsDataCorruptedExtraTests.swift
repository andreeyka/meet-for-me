//  PortsDataCorruptedExtraTests — К29 перечня MEE-189 (инвариант 21, восемь
//  портов §5), владелец: DEV-2. Разведён с `PortsDataCorruptedTests.swift` по
//  объёму (`type_body_length`) — не по смыслу: дополнительные входы сверх
//  «по одному битому на порт» из возвратов РП (перекрывающиеся segments,
//  корпус «три целые плюс одна битая» на методах-коллекциях, включая
//  adHoc()/unfinalized(), с сверкой entity И id).

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class PortsDataCorruptedExtraTests: StorageAsyncTestCase {

    // MARK: - Transcript: transcript(id:) — перекрывающиеся segments одного канала (инв. 14)

    func testK29_transcriptGivesDataCorruptedOnOverlappingSegmentsSameChannel() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordings = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()
        let recordingId = UUID()
        try await recordings.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        // Сохраняем валидную пару (второй начинается ровно там, где кончается
        // первый — граница разрешена, невалидный вход не пройдёт save()), затем
        // раздвигаем через Ш7: оба сегмента — канал .mic по умолчанию
        // TestFixtures.segment, второй теперь начинается раньше конца первого —
        // инвариант 14 (C-003) это отвергает только на сборке Transcript целиком,
        // не на хранении отдельных строк.
        let header = try await transcripts.save(try TestFixtures.transcript(
            recordingId: recordingId,
            segments: [
                try TestFixtures.segment(startMs: 0, endMs: 1_000, text: "a"),
                try TestFixtures.segment(startMs: 1_000, endMs: 2_000, text: "b")
            ]
        ))
        try temp.database.rawWrite { db in
            try db.execute(
                sql: "UPDATE segments SET start_ms = 500 WHERE transcript_id = ? AND start_ms = 1000",
                arguments: [header.id.uuidString]
            )
        }
        try await Self.assertDataCorrupted(entity: "Transcript", id: header.id.uuidString) {
            try await transcripts.transcript(id: header.id)
        }
    }

    // MARK: - Connector: all() — одна битая строка среди трёх целых

    func testK29_connectorsAllGivesDataCorruptedOnBrokenRowAmongThreeIntactRows() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let connectors = temp.database.connectorRepository()
        for suffix in ["a", "b", "c"] {
            try await connectors.upsert(ConnectorRecord(
                id: "intact-\(suffix)", type: "eventkit", pluginId: nil, settingsJson: Data(),
                keychainNamespace: "ns", selectedCalendarIds: [], isEnabled: true,
                lastSyncAt: nil, cursor: nil, lastError: nil
            ))
        }
        try await connectors.upsert(ConnectorRecord(
            id: "broken", type: "eventkit", pluginId: nil, settingsJson: Data(),
            keychainNamespace: "ns", selectedCalendarIds: [], isEnabled: true,
            lastSyncAt: nil, cursor: nil, lastError: nil
        ))
        try temp.database.rawWrite { db in
            try db.execute(sql: "UPDATE connectors SET selected_calendar_ids_json = 'not-json' WHERE id = 'broken'")
        }
        // Три целые строки не маскируют битую — метод-коллекция не пропускает
        // её молча (инвариант 21: dataCorrupted, а не тихий пропуск строки).
        try await Self.assertDataCorrupted(entity: "Connector", id: "broken") { try await connectors.all() }
    }

    // MARK: - Recording: unfinalized() — три целые строки плюс одна битая

    func testK29_recordingUnfinalizedGivesDataCorruptedOnBrokenRowAmongThreeIntactRows() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordings = temp.database.recordingRepository(fileLayout: layout)
        for _ in 0..<3 {
            try await recordings.save(RecordingRecord(
                manifest: try TestFixtures.recordingManifest(), status: .recording
            ))
        }
        let brokenId = UUID()
        try await recordings.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: brokenId), status: .recording
        ))
        try temp.database.rawWrite { db in
            try db.execute(
                sql: "UPDATE recordings SET manifest_json = 'not-json' WHERE id = ?", arguments: [brokenId.uuidString]
            )
        }
        try await Self.assertDataCorrupted(entity: "Recording", id: brokenId.uuidString) {
            try await recordings.unfinalized()
        }
    }

    // MARK: - Recording: adHoc() — три целые строки плюс одна битая

    func testK29_recordingAdHocGivesDataCorruptedOnBrokenRowAmongThreeIntactRows() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordings = temp.database.recordingRepository(fileLayout: layout)
        for _ in 0..<3 {
            try await recordings.save(RecordingRecord(
                manifest: try TestFixtures.recordingManifest(meetingId: nil), status: .recording
            ))
        }
        let brokenId = UUID()
        try await recordings.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: brokenId, meetingId: nil), status: .recording
        ))
        try temp.database.rawWrite { db in
            try db.execute(
                sql: "UPDATE recordings SET manifest_json = 'not-json' WHERE id = ?", arguments: [brokenId.uuidString]
            )
        }
        try await Self.assertDataCorrupted(entity: "Recording", id: brokenId.uuidString) {
            try await recordings.adHoc()
        }
    }

    // MARK: - Оснастка

    private static func assertDataCorrupted<T>(
        entity: String, id: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> T
    ) async throws {
        do {
            _ = try await body()
            XCTFail("ожидался dataCorrupted", file: file, line: line)
        } catch let error as StorageError {
            guard case .dataCorrupted(let gotEntity, let gotId, _) = error else {
                XCTFail("ожидался dataCorrupted, получено \(error)", file: file, line: line); return
            }
            XCTAssertEqual(gotEntity, entity, file: file, line: line)
            XCTAssertEqual(gotId, id, "id — битой строки среди целых, не заглушка", file: file, line: line)
        }
    }
}
