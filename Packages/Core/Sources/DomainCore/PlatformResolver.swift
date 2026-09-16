//  PlatformResolver — контракт C-009 (MEE-15), §2 «JoinInfo и PlatformResolver»
//  и §4.1 «Правило сравнения процесса с таблицей»
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Только объявления (MEE-86). Реализацию протокола и сами таблицы правил пишет модуль `detector`
//  (Packages/Mac/Sources/Detector/); фейк `FixedPlatformResolver` лежит в соседнем таргете
//  этого пакета — Packages/Core/Sources/DomainTestKit/.
//  §1 контракта (AudioProcess, ProcessGroup, MeetingSignal, порт) — в ProcessMonitorPort.swift.
//
//  Порядок типов и порядок полей внутри типа — дословно по §2 контракта
//  (порядок значим: правило обхода C-001 §0.2 п. 9).

import Foundation

public struct JoinInfo: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case conferenceField   // структурное поле события у источника
        case location
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

/// Резолвер площадок C-009 §2. Порядок требований — дословно по §2 и значим: правило обхода
/// C-001 §0.2 п. 9 распространено на объявления этого файла его же шапкой.
///
/// Разбор события (`resolve(event:)`) несёт инварианты 3, 4 и 5 контракта: порядок полей
/// `conference` → `location` → `bodyText`, первое совпадение побеждает, и
/// единственное исключение из правила `nil` — структурное поле `conference` с абсолютным
/// `https`-URL, не совпавшим ни с одним правилом. Через `resolve(text:source:)` эти инварианты
/// не проверяются: у текста полей нет.
public protocol PlatformResolver: Sendable {
    func resolve(event: MeetingEvent) -> JoinInfo?
    func resolve(text: String, source: JoinInfo.Source) -> JoinInfo?
    func clientBundleIds(for provider: String) -> [String]
    func allKnownClientBundleIds() -> [String]
    func provider(forAppKey appKey: String) -> String?
    func isBrowser(appKey: String) -> Bool
}
