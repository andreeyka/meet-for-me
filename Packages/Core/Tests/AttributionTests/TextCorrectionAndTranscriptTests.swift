//  TextCorrectionAndTranscriptTests — MEE-382 группа В, К13-К17: инв. 8 со стороны порта,
//  неприкосновенность транскрипта, постправка словарём имён (C-015 §6, инв. 13-16).
//
//  Пары слово/форма подобраны под собственный алгоритм близости этого модуля (нормированное
//  расстояние Левенштейна, регистронезависимо — SpeakerAttribution+Similarity): «Анна.» против
//  формы «Анна» — одна вставка на пять символов, `similarity == 0.8`, ровно порог по умолчанию.

import Foundation
import XCTest
import DomainCore
@testable import Attribution

final class TextCorrectionAndTranscriptTests: XCTestCase {
    private let port = SpeakerAttribution()

    func test_k13_userEditedSegmentsNeverInSegmentUpdates() async throws {
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0),
            SegmentSpec(channel: .system, cluster: 1)
        ], speakers: [try Fixture.speaker(0), try Fixture.speaker(1)])
        let input = Fixture.input(transcript: transcript, segmentIds: segmentIds, userEditedSegmentIds: [1])

        let result = try await port.attribute(input, thresholds: .slice1Defaults)

        XCTAssertFalse(result.segmentUpdates.contains { $0.segmentId == 1 })
        XCTAssertTrue(result.segmentUpdates.contains { $0.segmentId == 2 })
    }

    func test_k14_noTranscriptMutationAndProtocolStructurallyExcludesIt() async throws {
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0)
        ], speakers: [try Fixture.speaker(0)])
        let input = Fixture.input(transcript: transcript, segmentIds: segmentIds)

        let result = try await port.attribute(input, thresholds: .slice1Defaults)

        // Мех.-часть: у `AttributionResult` нет свойства типа `Transcript` ни на одном уровне —
        // разбор через `Mirror`, а не только чтение объявления, тем же доводом, что и у
        // остальных мех.-критериев этого перечня (наблюдаемый факт, не декларация).
        let hasTranscriptField = Mirror(reflecting: result).children.contains {
            "\(type(of: $1))" == "Transcript"
        }
        XCTAssertFalse(hasTranscriptField, "AttributionResult не обязан и не должен нести Transcript")

        // Мех.-часть (MEE-411, правка по приёмке РП 00:42 UTC на #131): предыдущая версия
        // сверяла строки, записанные в этом же тесте, — вакуумная проверка, зелёная при
        // любом изменении протокола. Здесь читается реальный исходник `AttributionPort.swift`
        // через `#filePath`, тем же приёмом, что `PortDeclarationTests:165` (DomainCoreTests);
        // копия приёма, не импорт — `AttributionTests` не видит `DomainCoreTests` (разные
        // таргеты SPM).
        let requirements = try Self.attributionPortRequirements()
        XCTAssertEqual(requirements.count, 3, "протокол должен объявлять ровно три метода")
        for requirement in requirements {
            XCTAssertFalse(requirement.contains("Transcript"),
                            "\(requirement) не должна принимать/возвращать Transcript")
        }
    }

    /// Тело протокола `AttributionPort` из реального файла, а не из строк этого теста.
    private static func attributionPortRequirements() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DomainCore/AttributionPort.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let header = "public protocol AttributionPort: Sendable {"
        guard let headerRange = text.range(of: header) else {
            struct HeaderNotFound: Error {}
            throw HeaderNotFound()
        }
        var depth = 1
        var body = ""
        var index = headerRange.upperBound
        while index < text.endIndex, depth > 0 {
            let character = text[index]
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if depth > 0 { body.append(character) }
            index = text.index(after: index)
        }
        var requirements: [String] = []
        for rawLine in body.components(separatedBy: .newlines) {
            let line = (rawLine.components(separatedBy: "//").first ?? "").trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("func ") {
                requirements.append(line)
            } else if !requirements.isEmpty {
                requirements[requirements.count - 1] += " " + line
            }
        }
        return requirements
    }

    func test_k15_lowConfidenceWordOnlyCandidateForCorrection() async throws {
        let ivan = Fixture.uuid(1)
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0, words: [("Анна.", 0.4), ("Анна.", nil)])
        ], speakers: [try Fixture.speaker(0)])
        let nameForms = [NameForm(personId: ivan, form: "Анна", kind: .full)]
        let input = Fixture.input(transcript: transcript, segmentIds: segmentIds, nameForms: nameForms)

        let result = try await port.attribute(input, thresholds: .slice1Defaults)

        XCTAssertEqual(result.textCorrections.count, 1)
        XCTAssertEqual(result.textCorrections.first?.wordIndex, 0)
    }

    func test_k16_belowSimilarityOrNoOpReplacementYieldsNoCorrection() async throws {
        let anna = Fixture.uuid(1)
        let (transcript, segmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0, words: [("Дом", 0.4)])
        ], speakers: [try Fixture.speaker(0)])
        let belowSimilarity = Fixture.input(
            transcript: transcript, segmentIds: segmentIds,
            nameForms: [NameForm(personId: anna, form: "Анна", kind: .full)]
        )
        let belowResult = try await port.attribute(belowSimilarity, thresholds: .slice1Defaults)
        XCTAssertTrue(belowResult.textCorrections.isEmpty)

        let (exactTranscript, exactSegmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0, words: [("Анна", 0.4)])
        ], speakers: [try Fixture.speaker(0)])
        let noOpInput = Fixture.input(
            transcript: exactTranscript, segmentIds: exactSegmentIds,
            nameForms: [NameForm(personId: anna, form: "Анна", kind: .full)]
        )
        let noOpResult = try await port.attribute(noOpInput, thresholds: .slice1Defaults)
        XCTAssertTrue(noOpResult.textCorrections.isEmpty, "original == replacement — не правка")
    }

    func test_k17_nameDictionaryLosesToMicChannelRule() async throws {
        let anna = Fixture.uuid(1)
        let nameForms = [NameForm(personId: anna, form: "Анна", kind: .full)]

        let (systemTranscript, systemSegmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .system, cluster: 0, words: [("Анна.", 0.4)])
        ], speakers: [try Fixture.speaker(0)])
        let systemInput = Fixture.input(
            transcript: systemTranscript, segmentIds: systemSegmentIds, nameForms: nameForms
        )
        let systemResult = try await port.attribute(systemInput, thresholds: .slice1Defaults)
        let systemUpdate = try XCTUnwrap(systemResult.segmentUpdates.first { $0.segmentId == 1 })
        XCTAssertEqual(systemUpdate.attributionSource, .nameDictionary)

        let (micTranscript, micSegmentIds) = try Fixture.transcript([
            SegmentSpec(channel: .mic, words: [("Анна.", 0.4)])
        ])
        let micInput = Fixture.input(transcript: micTranscript, segmentIds: micSegmentIds, nameForms: nameForms)
        let micResult = try await port.attribute(micInput, thresholds: .slice1Defaults)
        let micUpdate = try XCTUnwrap(micResult.segmentUpdates.first { $0.segmentId == 1 })
        XCTAssertEqual(micUpdate.attributionSource, .micChannel, "правило 1 побеждает постправку при любом me")
    }
}
