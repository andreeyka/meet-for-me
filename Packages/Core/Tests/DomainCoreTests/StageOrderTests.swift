//  Пп. 132—135, 143: перестановка ступеней, порядок внутри (в), тип-проверяющий,
//  порядок отказа на пути из JSON и `DomainValidationError` как значение.
//
//  Все векторы п. 132 собраны в коде: из JSON перестановка ступеней не наблюдается вовсе —
//  значение, нарушающее п. 9, отсекается при разборе.

import XCTest
import DomainCore

final class StageOrderTests: XCTestCase {

    /// Значение вне диапазона §0.2 п. 9 для поля `Date`: год около 300 000.
    private let farDate = Date(timeIntervalSince1970: 9_400_000_000_000)

    // MARK: - п. 132

    func test_p132_stageCBeforeB_c001_inv1() throws {
        assertInvariant(try DateProbe.event(start: farDate,
                                            end: Date(timeIntervalSince1970: 1_789_117_200)),
                        contract: "C-001", type: "MeetingEvent", invariant: 0, path: "start")
        assertInvariant(try DateProbe.event(start: Date(timeIntervalSince1970: 1_789_117_200),
                                            end: Date(timeIntervalSince1970: 1_789_113_600)),
                        contract: "C-001", type: "MeetingEvent", invariant: 1, path: "end")
    }

    func test_p132_stageCBeforeB_c001_inv2and4and7() throws {
        assertInvariant(try EventProbe.event(timeZone: "Nowhere/Nothing", lastModified: farDate),
                        contract: "C-001", type: "MeetingEvent", invariant: 0,
                        path: "lastModified")
        assertInvariant(try EventProbe.event(timeZone: "Nowhere/Nothing"),
                        contract: "C-001", type: "MeetingEvent", invariant: 2, path: "timeZone")
        assertInvariant(try EventProbe.event(duplicateAddresses: true, lastModified: farDate),
                        contract: "C-001", type: "MeetingEvent", invariant: 0,
                        path: "lastModified")
        assertInvariant(try EventProbe.event(duplicateAddresses: true),
                        contract: "C-001", type: "MeetingEvent", invariant: 4, path: "attendees")
        assertInvariant(try EventProbe.allDayWithBrokenEnd(lastModified: farDate),
                        contract: "C-001", type: "MeetingEvent", invariant: 0,
                        path: "lastModified")
        assertInvariant(try EventProbe.allDayWithBrokenEnd(),
                        contract: "C-001", type: "MeetingEvent", invariant: 7, path: "end")
    }

    func test_p132_stageCBeforeB_c002_rootInvariants() throws {
        for violation in ManifestProbe.rootViolations {
            assertInvariant(try ManifestProbe.manifest(violation: violation, startedAt: farDate),
                            contract: "C-002", type: "RecordingManifest", invariant: 0,
                            path: "startedAt")
            let fields = errorFields(try ManifestProbe.manifest(violation: violation))
            XCTAssertEqual(fields?.invariant, violation.invariant, "\(violation.invariant)")
        }
    }

    func test_p132_stageCBeforeB_c002_nestedInvariants() throws {
        assertInvariant(try RecordingManifest.Track(channel: .mic, fileName: "../db.sqlite",
                                                    sampleRate: 1 << 53, channelCount: 1,
                                                    format: "pcm-caf"),
                        contract: "C-002", type: "RecordingManifest.Track", invariant: 0,
                        path: "sampleRate")
        assertInvariant(try RecordingManifest.Track(channel: .mic, fileName: "../db.sqlite",
                                                    sampleRate: 48_000, channelCount: 1,
                                                    format: "pcm-caf"),
                        contract: "C-002", type: "RecordingManifest.Track", invariant: 3,
                        path: "fileName")
        assertInvariant(try RecordingManifest.Marker(kind: .sleep, atMs: -(1 << 53), detail: nil),
                        contract: "C-002", type: "RecordingManifest.Marker", invariant: 0,
                        path: "atMs")
        assertInvariant(try RecordingManifest.InputDeviceSpan(atMs: 1 << 53, present: false,
                                                              name: "AirPods", uid: nil),
                        contract: "C-002", type: "RecordingManifest.InputDeviceSpan",
                        invariant: 0, path: "atMs")
        assertInvariant(try RecordingManifest.InputDeviceSpan(atMs: 0, present: false,
                                                              name: "AirPods", uid: nil),
                        contract: "C-002", type: "RecordingManifest.InputDeviceSpan",
                        invariant: 17, path: "name")
    }

    func test_p132_stageCBeforeB_c003() throws {
        assertInvariant(try TranscriptProbe.transcript(violation: .unsortedSegments,
                                                       createdAt: farDate),
                        contract: "C-003", type: "Transcript", invariant: 0, path: "createdAt")
        assertInvariant(try TranscriptProbe.transcript(violation: .unsortedSegments),
                        contract: "C-003", type: "Transcript", invariant: 3,
                        path: "segments[2].startMs")
        assertInvariant(try TranscriptProbe.transcript(violation: .missingCluster,
                                                       createdAt: farDate),
                        contract: "C-003", type: "Transcript", invariant: 0, path: "createdAt")
        assertInvariant(try TranscriptProbe.transcript(violation: .badLanguage, createdAt: farDate),
                        contract: "C-003", type: "Transcript", invariant: 0, path: "createdAt")
        assertInvariant(try TranscriptProbe.transcript(violation: .badLanguage),
                        contract: "C-003", type: "Transcript", invariant: 13, path: "language")
        assertInvariant(try Transcript.Word(startMs: 0, endMs: -(1 << 53), text: "да",
                                            confidence: nil, original: nil),
                        contract: "C-003", type: "Transcript.Word", invariant: 0, path: "endMs")
        assertInvariant(try Transcript.Word(startMs: 0, endMs: 0, text: "да",
                                            confidence: 1.0000001, original: nil),
                        contract: "C-003", type: "Transcript.Word", invariant: 7,
                        path: "confidence")
        assertInvariant(try Transcript.Word(startMs: 0, endMs: 0, text: "да",
                                            confidence: .nan, original: nil),
                        contract: "C-003", type: "Transcript.Word", invariant: 0,
                        path: "confidence")
    }

    // MARK: - п. 133

    func test_p133_orderWithinStageC_followsDeclarationOrder() throws {
        assertInvariant(try Transcript.Segment(startMs: 1 << 53, endMs: (1 << 53) + 1,
                                               channel: .system, speakerCluster: 1 << 53,
                                               text: "да", textOriginal: nil,
                                               textConfidence: .nan, words: []),
                        contract: "C-003", type: "Transcript.Segment", invariant: 0,
                        path: "startMs")
        assertInvariant(try Transcript.Word(startMs: 0, endMs: 1 << 53, text: "да",
                                            confidence: .nan, original: nil),
                        contract: "C-003", type: "Transcript.Word", invariant: 0, path: "endMs")
        assertInvariant(try RecordingManifest.Discontinuity(atMs: 1 << 53, gapMs: -(1 << 53),
                                                            scaleErrorMs: 0, reason: .rebuild),
                        contract: "C-002", type: "RecordingManifest.Discontinuity",
                        invariant: 0, path: "atMs")
        assertInvariant(try Transcript.Speaker(cluster: 0, embedding: [1.0, .infinity, .nan],
                                               embeddingModelVersion: "v1", totalMs: 0),
                        contract: "C-003", type: "Transcript.Speaker", invariant: 0,
                        path: "embedding[1]")
        assertInvariant(try DateProbe.event(end: farDate, lastModified: farDate),
                        contract: "C-001", type: "MeetingEvent", invariant: 0, path: "end")
    }

    // MARK: - п. 134

    /// Пара «корневой против вложенного» на каждый контракт: без неё реализация, всегда
    /// сообщающая корневой тип, остаётся зелёной.
    func test_p134_typeEqualsTheCheckingType() throws {
        XCTAssertEqual(errorFields(try decodeEvent(EventJSON.text(
            timeZone: "\"Nowhere/Nothing\"")))?.type, "MeetingEvent")
        XCTAssertEqual(errorFields(try decodeEvent(EventJSON.text(
            attendees: "[\(EventJSON.attendee(email: "\"ivan\""))]")))?.type,
            "MeetingEvent.Person")
        XCTAssertEqual(errorFields(try decodeManifest(ManifestJSON.text(tracks: "[]")))?.type,
                       "RecordingManifest")
        XCTAssertEqual(errorFields(try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(format: "\"flac\""))]",
            isFinalized: "false")))?.type, "RecordingManifest.Track")
        XCTAssertEqual(errorFields(try decodeTranscript(TranscriptJSON.text(
            language: "\"RU\"")))?.type, "Transcript")
        XCTAssertEqual(errorFields(try decodeTranscript(TranscriptJSON.text(
            speakers: "[\(TranscriptJSON.speaker(totalMs: "-1"))]")))?.type, "Transcript.Speaker")
    }

    /// Составной путь наблюдается только у классов 2 и 3 §0.1 и у инвариантов класса 1,
    /// которые вложенному типу проверить нечем; во всех остальных случаях путь короткий.
    func test_p134_compositePathsAreClosedList() throws {
        let composite = [
            errorFields(try decodeManifest(ManifestJSON.text(
                markers: "[\(ManifestJSON.marker(atMs: "5")), \(ManifestJSON.marker(atMs: "1"))]")))?.path,
            errorFields(try decodeTranscript(TranscriptJSON.text(
                segments: "[\(TranscriptJSON.segment(channel: "\"system\"", speakerCluster: "7"))]")))?.path
        ]
        XCTAssertEqual(composite, ["markers[1].atMs", "segments[0].speakerCluster"])
        let short = [
            errorFields(try RecordingManifest.Marker(kind: .sleep, atMs: -1, detail: nil))?.path,
            errorFields(try Transcript.Speaker(cluster: -1, embedding: nil,
                                               embeddingModelVersion: nil, totalMs: 0))?.path
        ]
        XCTAssertEqual(short, ["atMs", "cluster"])
    }

    // MARK: - п. 135

    /// Шаг 1 раньше всего: повторяющийся ключ в последнем объекте файла сообщается раньше
    /// негодного числа в первом поле корня.
    func test_p135_duplicateKeysComeBeforeAnythingElse() throws {
        let broken = TranscriptJSON.text(schemaVersion: "9007199254740992",
                                         tail: ", \"language\": \"en\"")
        assertCorrupted(try decodeTranscript(broken), key: "language")
    }

    func test_p135_fieldsAreDecodedInDeclarationOrder() throws {
        let word = TranscriptJSON.word(startMs: "9007199254740992", endMs: "9007199254740993")
        XCTAssertEqual(corruptedPath(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(TranscriptJSON.segment(words: "[\(word)]"))]"))).last, "startMs")
        let speaker = TranscriptJSON.speaker(embedding: "[1e400]",
                                             embeddingModelVersion: "\"v1\"",
                                             totalMs: "9007199254740992")
        XCTAssertEqual(corruptedPath(try decodeTranscript(
            TranscriptJSON.text(speakers: "[\(speaker)]"))).last, "embedding")
    }

    /// Негодное значение взято целым вне §0.2 п. 9, а не литералом `1e400`: место отказа на
    /// литерале вне диапазона `Double` у `Foundation` разнится по сборкам, и вектор проверял бы
    /// не порядок отказа, а разбор чисел.
    func test_p135_nestedValueFailsBeforeParentReachesNextField() throws {
        let broken = TranscriptJSON.word(endMs: "9007199254740992")
        let segment = TranscriptJSON.segment(words: "[\(broken)]")
        assertCorrupted(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(segment)]", speakers: "[\(TranscriptJSON.speaker(totalMs: "1.5"))]")),
            key: "endMs")
    }

    // MARK: - п. 143

    func test_p143_validationErrorIsAValue() throws {
        let failure = DomainValidationError(contract: "C-002", type: "RecordingManifest",
                                            invariant: 1, path: "schemaVersion", message: "текст")
        let back = try DomainJSON.decode(DomainValidationError.self,
                                         from: DomainJSON.encode(failure))
        XCTAssertEqual(back, failure)
        XCTAssertEqual(back.message, "текст")
        let other = DomainValidationError(contract: "C-002", type: "RecordingManifest",
                                          invariant: 2, path: "schemaVersion", message: "текст")
        XCTAssertNotEqual(failure, other)
    }

    /// Отсекающего механизма на поле `invariant` нет, и это решение, а не пробел.
    func test_p143_invariantFieldHasNoGuard() throws {
        let failure = DomainValidationError(contract: "C-002", type: "RecordingManifest",
                                            invariant: 1 << 53, path: "schemaVersion",
                                            message: "текст")
        XCTAssertEqual(failure.invariant, 1 << 53)
        let back = try DomainJSON.decode(DomainValidationError.self,
                                         from: DomainJSON.encode(failure))
        XCTAssertEqual(back, failure)
    }
}
