//  EngineStage, EngineProgress — C-011 v5 «Определение» §5: этапы движка и события хода
//  работы. Инвариант 10 (ровно один `.started`/`.finished` на этап) проверяет вызывающая
//  сторона по последовательности событий — не эта форма, ей нечем сравнить один снимок
//  с историей.
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (протоколы и сообщения)

public enum EngineStage: String, Codable, Equatable, Sendable, CaseIterable {
    case prepare
    case vad
    case asr
    case diarization
    case embedding
    case postProcess
}

/// `advanced.fraction` — `0...1` внутри этапа. Инвариант диапазона (§0 «ступень (б)» не
/// покрывает эту часть — не числовая представимость, а собственный инвариант, не проверен
/// здесь тем же доводом, что инварианты 6-9 `DiarizationResult`) НЕ проверяется этим типом;
/// проверяется только конечность (§0.2 п. 9) — путь построения из кода у перечисления с
/// ассоциированными значениями один (сам случай `.advanced(...)`), отдельного throwing-init
/// нет, поэтому непредставимое значение ловится ТОЛЬКО при разборе байтов (`decodeFinite`
/// бросает `DecodingError` до того, как код вообще получил бы значение на руки).
public enum EngineProgress: Codable, Equatable, Sendable {
    case started(stage: EngineStage)
    case advanced(stage: EngineStage, fraction: Double)
    case finished(stage: EngineStage)

    private enum CodingKeys: String, CodingKey {
        case kind, stage, fraction
    }

    private enum Kind: String, Codable {
        case started, advanced, finished
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let stage = try box.decode(EngineStage.self, forKey: .stage)
        switch try box.decode(Kind.self, forKey: .kind) {
        case .started:
            self = .started(stage: stage)
        case .finished:
            self = .finished(stage: stage)
        case .advanced:
            self = .advanced(stage: stage, fraction: try box.decodeFinite(Double.self, forKey: .fraction))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .started(let stage):
            try box.encode(Kind.started, forKey: .kind)
            try box.encode(stage, forKey: .stage)
        case .advanced(let stage, let fraction):
            try box.encode(Kind.advanced, forKey: .kind)
            try box.encode(stage, forKey: .stage)
            try box.encode(fraction, forKey: .fraction)
        case .finished(let stage):
            try box.encode(Kind.finished, forKey: .kind)
            try box.encode(stage, forKey: .stage)
        }
    }
}
