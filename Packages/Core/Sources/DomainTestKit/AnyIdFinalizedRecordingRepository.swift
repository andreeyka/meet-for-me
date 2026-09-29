//  AnyIdFinalizedRecordingRepository — хранилище записей для тестов транспорта engine-xpc
//  (MEE-480): с C-012 v12 §1.1 `EngineXPCClient` читает запись из `RecordingRepository` раньше
//  каталога моделей, а тестам транспорта и стороны сервиса запись безразлична. На любой
//  `recording(id:)` отдаётся пригодная запись с этим `id`: `.finalized`, дорожки `system`
//  (стерео) и `mic` (моно), `pcm-caf` 48 000 Гц, `isFinalized == false` (C-013 v16: в срезе 1
//  перекодирования нет). Остальные методы порта адаптер не вызывает (инв. 24) — здесь они
//  отвечают пустотой. Поведение по записи проверяют тесты на `InMemoryRecordingRepository`.
//
//  Здесь, а не в тестовых целях `Packages/Mac`, — MEE-488, п. 10: раньше класс был
//  продублирован в `EngineXPCClientTests` и `EngineXPCServiceTests` (тестовые цели друг друга
//  не импортируют), а `DomainTestKit` импортируют обе.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)

import Foundation
import DomainCore

public final class AnyIdFinalizedRecordingRepository: RecordingRepository, @unchecked Sendable {

    public init() {}

    /// Манифест — `RecordingFixtures.record` (MEE-495, п. 2): не повторяется здесь вручную.
    public func recording(id: UUID) async throws -> RecordingRecord? {
        try RecordingFixtures.record(recordingId: id)
    }

    public func save(_ record: RecordingRecord) async throws {}
    public func recordings(meetingId: UUID) async throws -> [RecordingRecord] { [] }
    public func unfinalized() async throws -> [RecordingRecord] { [] }
    public func adHoc() async throws -> [RecordingRecord] { [] }
    public func delete(recordingId: UUID, deleteFiles: Bool) async throws {}
    public func createDirectory(recordingId: UUID) async throws -> URL {
        URL(fileURLWithPath: "/dev/null").appendingPathComponent(recordingId.uuidString)
    }
}
