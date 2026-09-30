//  SpeakerAssignmentTests — версия эмбеддингов "" через фасад (MEE-498, из ревью #207/MEE-489):
//  `assignSpeaker`/`clearSpeaker` строят вход тем же `AttributionSupport.buildInput`, что и
//  `AttributeJobHandler`, и C-015 v11 §7 (IR-150) для них действует так же — спикеры без версий
//  дают "", охраны «испорченный вход» нет, порт зовётся, а профили голосов не читаются (сравнивать
//  не с чем). Разведено из тела класса по объёму (`type_body_length`).
//
//  Модуль: domain-core · Владелец: DEV-1 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

extension SpeakerAssignmentTests {

    private func emptyVersionFixture(voiceProfilesEnabled: Bool, version: String?) async throws -> Fixture {
        let fixture = try await makeFixture(embeddingModelVersion: version)
        try await fixture.repositories.settings.setValue(
            try DomainJSON.encode(voiceProfilesEnabled), forKey: "voiceProfilesEnabled"
        )
        fixture.attribution.forcedResult = AttributionResult(
            transcriptId: fixture.transcriptId, assignments: [], segmentUpdates: [], textCorrections: [],
            profileUpdates: []
        )
        return fixture
    }

    private func profilesReadCount(_ fixture: Fixture) -> Int {
        fixture.repositories.log.count(port: "SpeakerProfileRepository", method: "profiles(personIds:modelVersion:)")
    }

    /// `assignSpeaker`: спикеры без версий при включённых голосовых профилях — `confirm` вызван со
    /// входом `embeddingModelVersion == ""` и пустыми `profiles`, чтения профилей нет. Контроль —
    /// та же фикстура с версией "v1": профили читаются, версия доходит до входа.
    func test_emptyVersion_assignSpeakerCallsConfirmWithEmptyVersion() async throws {
        let fixture = try await emptyVersionFixture(voiceProfilesEnabled: true, version: nil)

        try await fixture.facade.assignSpeaker(transcriptId: fixture.transcriptId, cluster: 0, personId: UUID())

        XCTAssertEqual(fixture.attribution.confirmCallCount, 1)
        let input = try XCTUnwrap(fixture.attribution.lastConfirmedInput)
        XCTAssertEqual(input.embeddingModelVersion, "")
        XCTAssertEqual(input.profiles, [])
        XCTAssertEqual(profilesReadCount(fixture), 0)

        let control = try await emptyVersionFixture(voiceProfilesEnabled: true, version: "v1")
        try await control.facade.assignSpeaker(transcriptId: control.transcriptId, cluster: 0, personId: UUID())
        XCTAssertEqual(control.attribution.lastConfirmedInput?.embeddingModelVersion, "v1")
        XCTAssertEqual(profilesReadCount(control), 1)
    }

    /// `clearSpeaker`: то же для `reject`, при обоих значениях `voiceProfilesEnabled`.
    func test_emptyVersion_clearSpeakerCallsRejectWithEmptyVersion() async throws {
        for enabled in [false, true] {
            let fixture = try await emptyVersionFixture(voiceProfilesEnabled: enabled, version: nil)

            try await fixture.facade.clearSpeaker(transcriptId: fixture.transcriptId, cluster: 0)

            XCTAssertEqual(fixture.attribution.rejectCallCount, 1, "voiceProfilesEnabled=\(enabled)")
            let input = try XCTUnwrap(fixture.attribution.lastRejectedInput)
            XCTAssertEqual(input.embeddingModelVersion, "", "voiceProfilesEnabled=\(enabled)")
            XCTAssertEqual(input.voiceProfilesEnabled, enabled)
            XCTAssertEqual(profilesReadCount(fixture), 0, "voiceProfilesEnabled=\(enabled)")
        }
    }
}
