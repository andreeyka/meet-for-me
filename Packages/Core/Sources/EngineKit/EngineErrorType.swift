//  EngineError — C-011 v5 «Определение» §6: единственный отказ, который вправе бросить
//  любой из четырёх протоколов движка. Инвариант 1: `DomainValidationError`, пойманная у
//  результата (его же `init(...) throws`), уходит наружу обёрнутой в `.invalidResult`, а не
//  сама по себе — голый `DomainValidationError` никогда не пересекает границу этих протоколов.
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (протоколы и сообщения)
//
//  Ни одно поле не числовое — синтезированный `Codable` (все ассоциированные значения сами
//  `Codable`) читает байты без ступеней (в)/(б) этого модуля.

import DomainCore

public enum EngineError: Error, Codable, Equatable, Sendable {
    case modelMissing(modelId: String, version: String)
    case modelIncompatible(modelId: String, message: String)
    case audioUnreadable(path: String)
    case unsupportedLanguage(String)
    case unsupportedRequest(message: String)
    case outOfMemory
    case cancelled
    /// Инвариант 1: результат протокола (`Transcript`/`DiarizationResult`/…) не прошёл
    /// собственную валидацию своего throwing-init — реализация ловит и заворачивает сюда.
    case invalidResult(DomainValidationError)
    case runtimeFailure(message: String)
}
