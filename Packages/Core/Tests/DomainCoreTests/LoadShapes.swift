//  Большие валидные значения для пп. 79 и 119.
//
//  Эмбеддинги в замерном входе обязательны: без них проверка конечности в замер не попадает
//  вовсе. Элементы `discontinuities` обязательны по той же причине и по новой — инвариант 15
//  сравнивает две коллекции по кратности значений `atMs`.

import Foundation
import DomainCore

enum LoadShapes {

    static func transcript(segmentCount: Int, wordsPerSegment: Int,
                           speakerCount: Int, embeddingSize: Int) throws -> Transcript {
        let embedding = [Float](repeating: 0.5, count: embeddingSize)
        let speakers = try (0..<speakerCount).map { cluster in
            try Transcript.Speaker(cluster: cluster, embedding: embedding,
                                   embeddingModelVersion: "emb-v1", totalMs: 1_000)
        }
        let segments = try (0..<segmentCount).map { position -> Transcript.Segment in
            let base = position * 1_000
            let words = try (0..<wordsPerSegment).map { index -> Transcript.Word in
                try Transcript.Word(startMs: base + index * 80, endMs: base + index * 80 + 80,
                                    text: "слово", confidence: nil, original: nil)
            }
            return try Transcript.Segment(
                startMs: base, endMs: base + 900, channel: .system,
                speakerCluster: position % speakerCount, text: "речь",
                textOriginal: nil, textConfidence: nil, words: words
            )
        }
        return try Transcript(
            recordingId: try makeUUID("3F2504E0-4F89-41D3-9A0C-0305E82C3301"),
            language: "ru", engine: "gigaam-sherpa-onnx", modelVersion: "v3.0.1",
            createdAt: date(milliseconds: 1_789_122_912_000),
            segments: segments, speakers: speakers
        )
    }

    static func manifest(discontinuityCount: Int) throws -> RecordingManifest {
        let markers = try (0..<discontinuityCount).map { index in
            try RecordingManifest.Marker(kind: .discontinuity, atMs: index * 10, detail: nil)
        }
        let gaps = try (0..<discontinuityCount).map { index in
            try RecordingManifest.Discontinuity(atMs: index * 10, gapMs: 0,
                                                scaleErrorMs: 150, reason: .rebuild)
        }
        let recordingId = try makeUUID("3F2504E0-4F89-41D3-9A0C-0305E82C3301")
        return try RecordingManifest(
            recordingId: recordingId, meetingId: nil, directoryName: recordingId.uuidString,
            startedAt: date(milliseconds: 1_789_119_000_000),
            endedAt: date(milliseconds: 1_789_119_000_000 + discontinuityCount * 10 + 1_000),
            tracks: [try RecordingManifest.Track(channel: .mic, fileName: "m.caf",
                                                 sampleRate: 48_000, channelCount: 1,
                                                 format: "pcm-caf")],
            markers: markers, capturedProcesses: [], captureGroupKey: nil,
            inputDevices: [], discontinuities: gaps, isFinalized: false
        )
    }
}
