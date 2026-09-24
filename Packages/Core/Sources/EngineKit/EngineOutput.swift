//  MeetingOutputDraft (+ Kind) — C-011 v5 «Определение» §4: выход `PostProcessor.process`,
//  один документ на вызов (`process` возвращает массив — один запрос может дать несколько
//  черновиков разного рода за один проход).
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (протоколы и сообщения)

import Foundation
import DomainCore

public struct MeetingOutputDraft: Codable, Equatable, Sendable, DomainValidatable {

    public enum Kind: String, Codable, Equatable, Sendable {
        case summary
        case decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }

    public let kind: Kind
    public let contentMarkdown: String
    /// Структурированная форма того же содержимого (например, список пунктов JSON-байтами) —
    /// `nil`, если движок отдаёт только текст.
    public let structuredJson: Data?
    public let engine: String
    public let promptVersion: String

    public init(
        kind: Kind, contentMarkdown: String, structuredJson: Data?,
        engine: String, promptVersion: String
    ) throws {
        self.kind = kind
        self.contentMarkdown = contentMarkdown
        self.structuredJson = structuredJson
        self.engine = engine
        self.promptVersion = promptVersion
        try validate()
    }

    /// Нет собственных числовых полей — ступени (в)/(б) этому типу нечего проверять;
    /// throwing-init остаётся единственным путём построения по общему правилу §0.
    public func validate() throws {}
}
