//  TextCorrection — контракт C-015 (MEE-23), «Определение», постправка словарём имён
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Только объявление. Реализацию порта атрибуции пишет модуль `attribution`
//  (Packages/Core/Sources/Attribution/).
//
//  ПОЧЕМУ ЭТОТ ТИП ЗДЕСЬ, ХОТЯ МОДУЛЬ `attribution` ЕЩЁ НЕ РЕАЛИЗОВАН.
//  `TranscriptRepository.applyTextCorrections(segmentId:text:corrections:)` (C-010 v19,
//  инвариант 32, IR-129, MEE-388) несёт параметр `corrections: [TextCorrection]`. Объявить
//  порт, не объявив этот тип, нечем: он не компилируется. Разрешённые списки инварианта 19
//  и у C-010, и у C-015 называют `TextCorrection` прямо, с пометкой «(C-015)».
//  Назначения смысла типу здесь не делается ни одного: состав и комментарии — дословно
//  «Определение» C-015.

import Foundation

public struct TextCorrection: Codable, Equatable, Sendable {
    public let segmentId: Int64
    public let wordIndex: Int                    // индекс в Transcript.Segment.words
    public let original: String
    public let replacement: String
    public let personId: UUID                    // чьё имя подставлено
    public let similarity: Double                // 0...1, фонетическая близость

    public init(
        segmentId: Int64,
        wordIndex: Int,
        original: String,
        replacement: String,
        personId: UUID,
        similarity: Double
    ) {
        self.segmentId = segmentId
        self.wordIndex = wordIndex
        self.original = original
        self.replacement = replacement
        self.personId = personId
        self.similarity = similarity
    }
}
