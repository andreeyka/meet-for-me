//  PlatformResolver — контракт C-009 v2 (MEE-15), §2 «JoinInfo и PlatformResolver»
//  и §4.1 «Правило сравнения процесса с таблицей»
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Только объявления (MEE-86). Реализацию протокола и сами таблицы правил пишет модуль `detector`
//  (Packages/Mac/Sources/Detector/), фейк `FixedPlatformResolver` придёт отдельным пакетом DEV-2.
//  §1 контракта (AudioProcess, ProcessGroup, MeetingSignal, порт) — в ProcessMonitorPort.swift.
//
//  Порядок типов и порядок полей внутри типа — дословно по §2 контракта
//  (порядок значим: правило обхода C-001 §0.2 п. 9).

import Foundation

public struct JoinInfo: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case conferenceField   // структурное поле события у источника
        case location
        case eventUrl          // поле URL события
        case bodyText
    }

    public let provider: String          // ключ из таблицы правил; тот же набор, что в C-001
    public let joinUrl: URL
    public let meetingId: String?
    public let passcode: String?
    public let clientBundleIds: [String] // нативные клиенты провайдера; пустой — только браузер
    public let source: Source

    public init(
        provider: String,
        joinUrl: URL,
        meetingId: String?,
        passcode: String?,
        clientBundleIds: [String],
        source: Source
    ) {
        self.provider = provider
        self.joinUrl = joinUrl
        self.meetingId = meetingId
        self.passcode = passcode
        self.clientBundleIds = clientBundleIds
        self.source = source
    }
}

/// Правило сравнения §4.1. Чистая функция, объявлена в `domain-core` рядом с DTO таблиц.
///
/// Тело — дословная запись шага 2 §4.1: `k != nil && (k == B || k начинается с B + ".")`.
/// Оно здесь не реализация порта, а сам текст правила: `PlatformResolver` в `detector` обязан
/// звать эту функцию, а не собственное сравнение, иначе у двух путей чтения таблиц появятся
/// два мнения о том, что совпало.
public func bundleKeyMatches(appKey: String?, entry: String) -> Bool {
    guard let appKey else { return false }
    return appKey == entry || appKey.hasPrefix(entry + ".")
}

public protocol PlatformResolver: Sendable {
    // Метод `resolve(event: MeetingEvent) -> JoinInfo?` контракта C-009 §2 здесь НЕ объявлен,
    // и протокол объявлен неполно СОЗНАТЕЛЬНО: в контракте метод есть, а его аргумент
    // `MeetingEvent` принадлежит контракту C-001 и пишется задачей MEE-29 вместе с остальными DTO
    // (https://linear.app/easypto/issue/MEE-29). Объявить метод здесь значило бы завести второй
    // источник истины для чужого типа; отсутствие метода — граница задачи MEE-86, а не забывчивость.
    // Решение РП и три отвергнутых варианта — в комментарии «ПРАВКА ПОСТАНОВКИ» к MEE-86:
    // https://linear.app/easypto/issue/MEE-86#comment-0ee73914
    // Следствие, записанное РП на свою сторону: инварианты C-009 3, 4 и 5 (порядок разбора события
    // conference → location → eventUrl → bodyText и правило возврата nil) проверяются только через
    // этот метод и потому лежат вне объёма MEE-67 до прихода DTO C-001.
    func resolve(text: String, source: JoinInfo.Source) -> JoinInfo?
    func clientBundleIds(for provider: String) -> [String]
    func allKnownClientBundleIds() -> [String]
    func provider(forAppKey appKey: String) -> String?
    func isBrowser(appKey: String) -> Bool
}
