//  Правила входа в запись и выхода из неё чистыми функциями — контракт C-018 (MEE-276):
//  §7 (клаузы строк 6, 8, 9 и 10), §7.1, §8.2, §8.4, §8.7.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧАСТЬ B задачи MEE-300. Файл отделён от `SessionMachineRules.swift` по одному доводу, и
//  он механический: `--strict` линта считает файл длиннее четырёхсот строк нарушением.
//  Правила остаются членами того же `SessionMachineRules` — второго места для правил
//  машины не заводится (К4, К19).
//
//  ЗДЕСЬ НЕТ НИ СОСТОЯНИЯ, НИ ПОРТОВ, НИ `Date()`: «сейчас» приходит параметром (§4).

import Foundation

extension SessionMachineRules {

    // MARK: - §7, строки 6 и 8: три клаузы разом

    /// Три клаузы строк 6 и 8, собранные ОДНИМ значением.
    ///
    /// Значением, а не тремя параметрами, потому что строки 6, 8 и 16 требуют их **разом**,
    /// а клауза строки 9 — их отрицания **разом же**: два места, читающие один предикат
    /// порознь, расходятся молча. Ровно это и случилось с прежней клаузой строки 9, которая
    /// читала одну треть предиката (C-018 v5, §«Ломающие изменения против v4», место 1).
    struct RecordingGate: Equatable {

        /// §5.3: у сессии есть звучащая цель. Оспариваемая цель (§5.4) звучащей не является
        /// и сюда не приходит — это и есть первый из трёх случаев клаузы строки 9.
        let hasTarget: Bool

        /// §7.1: цель занята идущей записью ДРУГОЙ сессии.
        let isTargetTaken: Bool

        /// §8.2: запись разрешена политикой.
        let isAllowedByPolicy: Bool

        /// Условие строк 6, 8 и 16 целиком.
        var maySwitchToRecording: Bool {
            hasTarget && !isTargetTaken && isAllowedByPolicy
        }

        /// Пустой замок: цели нет, и потому не занята и политикой не отдана. Значение для
        /// состояний, в которых строки 6 и 8 не читаются вовсе.
        static let closed = RecordingGate(
            hasTarget: false, isTargetTaken: false, isAllowedByPolicy: false
        )
    }

    // MARK: - §8.2: что разрешает политика

    /// Отдаёт ли политика звучащую цель строкам 6, 8 и 16 в этот момент.
    ///
    /// `.auto` — да, спроса нет вовсе; `.ask` — только после ответа `.record`; `.manual` —
    /// никогда, запись начинается единственно командой `startRecording`. `.manual` есть
    /// отказ от автоматики, а не её отсрочка (К52).
    static func policyAllowsRecording(
        policy: AppSettings.RecordingPolicy,
        recordAnswered: Bool
    ) -> Bool {
        switch policy {
        case .auto:
            return true
        case .ask:
            return recordAnswered
        case .manual:
            return false
        }
    }

    // MARK: - §8.4: момент остановки по тишине

    /// Момент, в который сессия уходит из `recording` в `stopping` по правилу 2 §8.4.
    ///
    /// Отсчёт идёт от момента, в который цель **выпала из слияния**, — то есть от
    /// `observedAt` последней актуальной цели плюс `signalTtlSeconds` (C-009 §1), — а НЕ
    /// от момента, когда машина это заметила. Реализация, считающая от замеченного,
    /// опаздывает ровно на задержку замечания, и ровно эту разницу подаёт К57.
    static func silenceStopsAt(
        lastTargetObservedAt: Date,
        settings: AppSettings,
        weights: SignalWeights
    ) -> Date {
        lastTargetObservedAt
            .addingTimeInterval(TimeInterval(weights.signalTtlSeconds))
            .addingTimeInterval(TimeInterval(settings.silenceStopSeconds))
    }

    // MARK: - §8.7: цепочка обработки

    /// Следующее звено цепочки `transcode → transcribe → diarize → attribute` после
    /// успешно завершённого `completed`; `nil` — цепочка кончилась.
    ///
    /// Пятого звена нет: `summarize` в Срезе 1 не ставится — обработчик его не
    /// зарегистрирован, и задача повисла бы в очереди навсегда (К65).
    static func nextInChain(after completed: JobType) -> JobType? {
        switch completed {
        case .transcode:
            return .transcribe
        case .transcribe:
            return .diarize
        case .diarize:
            return .attribute
        case .attribute, .summarize:
            return nil
        }
    }

    /// Порядок цепочки §8.7 целиком — одно место, из которого читают и первое звено, и
    /// проверка «задача принадлежит цепочке».
    static let processingChain: [JobType] = [.transcode, .transcribe, .diarize, .attribute]
}
