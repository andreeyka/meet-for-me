//  AttributionTestSupport — общие строители фикстур для тестов MEE-406 (перечень MEE-382,
//  группы А-Г, Е, Ж, О; владелец теста — DEV-2). Не `DomainTestKit.AttributionFixtures`
//  (MEE-399, шесть именованных входов «Фейка для тестов») — здесь построители для
//  К-специфичных входов, по одному сценарию на критерий, не для повторного использования
//  чужими модулями.

import DomainCore
import Foundation

/// Один сегмент будущего транскрипта. Слова — `(text, confidence)`; `textConfidence`
/// считается билдером сам (инв. 8 C-003: минимум по словам, если у всех есть уверенность).
struct SegmentSpec {
    let channel: RecordingManifest.Channel
    let cluster: Int?
    let text: String
    let words: [(text: String, confidence: Double?)]

    init(channel: RecordingManifest.Channel, cluster: Int? = nil, text: String = "текст",
         words: [(text: String, confidence: Double?)] = []) {
        self.channel = channel
        self.cluster = cluster
        self.text = text
        self.words = words
    }
}

enum Fixture {
    static let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    static func uuid(_ tag: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", tag))!
    }

    static func person(_ tag: Int, name: String, isMe: Bool = false) -> PersonRecord {
        PersonRecord(id: uuid(tag), displayName: name, emails: [], isMe: isMe)
    }

    static func speaker(
        _ cluster: Int, embedding: [Float]? = nil, version: String? = "v1", totalMs: Int = 1000
    ) throws -> Transcript.Speaker {
        try Transcript.Speaker(
            cluster: cluster, embedding: embedding,
            embeddingModelVersion: embedding == nil ? nil : version, totalMs: totalMs
        )
    }

    static func profile(
        _ personTag: Int, embedding: [Float], version: String = "v1", sampleCount: Int = 4
    ) -> SpeakerProfile {
        SpeakerProfile(
            personId: uuid(personTag), embedding: embedding, modelVersion: version,
            sampleCount: sampleCount, updatedAt: createdAt
        )
    }

    /// Каждый спек получает окно в 1000 мс подряд (порядок сегментов — порядок специфаций,
    /// инв. 3 C-003: неубывание `startMs`), слова внутри окна — по 100 мс подряд с начала окна.
    /// `segmentIds` — `1...n`, тем же порядком (C-015 §2: «в порядке transcript.segments»).
    static func transcript(
        _ specs: [SegmentSpec], speakers: [Transcript.Speaker] = []
    ) throws -> (transcript: Transcript, segmentIds: [Int64]) {
        var segments: [Transcript.Segment] = []
        for (index, spec) in specs.enumerated() {
            let start = index * 1_000
            let end = start + 1_000
            var words: [Transcript.Word] = []
            var cursor = start
            for wordSpec in spec.words {
                let wordEnd = cursor + 100
                words.append(try Transcript.Word(
                    startMs: cursor, endMs: wordEnd, text: wordSpec.text,
                    confidence: wordSpec.confidence, original: nil
                ))
                cursor = wordEnd
            }
            let confidences = words.compactMap(\.confidence)
            let textConfidence: Double? = (!words.isEmpty && confidences.count == words.count) ? confidences.min() : nil
            segments.append(try Transcript.Segment(
                startMs: start, endMs: end, channel: spec.channel, speakerCluster: spec.cluster,
                text: spec.text, textOriginal: nil, textConfidence: textConfidence, words: words
            ))
        }
        let transcript = try Transcript(
            recordingId: UUID(), language: "ru", engine: "gigaam-sherpa-onnx", modelVersion: "v3.0.1",
            createdAt: createdAt, segments: segments, speakers: speakers
        )
        let segmentIds = (0..<Int64(specs.count)).map { $0 + 1 }
        return (transcript, segmentIds)
    }

    static func input(
        transcriptId: UUID = UUID(),
        transcript: Transcript,
        segmentIds: [Int64],
        attendees: [PersonRecord] = [],
        me: PersonRecord? = nil,
        nameForms: [NameForm] = [],
        profiles: [SpeakerProfile] = [],
        voiceProfilesEnabled: Bool = true,
        embeddingModelVersion: String = "v1",
        userEditedSegmentIds: [Int64] = []
    ) -> AttributionInput {
        AttributionInput(
            transcriptId: transcriptId, transcript: transcript, segmentIds: segmentIds, meetingId: nil,
            attendees: attendees, me: me, nameForms: nameForms, profiles: profiles,
            voiceProfilesEnabled: voiceProfilesEnabled, embeddingModelVersion: embeddingModelVersion,
            userEditedSegmentIds: userEditedSegmentIds
        )
    }
}
