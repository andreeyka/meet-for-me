//  EventKitGateway — шов модуля, MEE-339 раздел «Шов».
//
//  Модуль: calendar-eventkit · Владелец: DEV-1 · Слой: плагин (адаптер системного API)
//
//  Три операции перечня, форма — моя (MEE-339, «Шов»: «форму… выбирает DEV-1»):
//  1. список календарей пользователя (`calendars()`);
//  2. события в диапазоне дат по списку календарей, уже развёрнутые по правилу повторения,
//     с исходными (НЕ нормализованными) полями EventKit — нормализацию делает коннектор
//     (IR-116), не шов;
//  3. различить «похоже на потерю права» и «иная причина» — двумя разными случаями ошибки
//     (`EventKitGatewayError`), не одним общим (развилка Р7).
//
//  Шов не несёт авторизации: ни один метод здесь не проверяет и не запрашивает право
//  `.calendars` — это целиком обязанность `PermissionsPort`, см. `EventKitConnector`.

import Foundation

/// Ошибка шва — различает «похоже на потерю права» (Р7) от «иной причины». Реализация
/// `EventKitCoreGateway` калибрует классификацию по коду/типу ошибки `EKEventStore`;
/// эвристика без М2 (живой Mac) не проверена, см. её файл.
enum EventKitGatewayError: Error, Sendable {
    case looksLikePermissionLoss(message: String)
    case other(message: String)
}

/// Календарь источника — поля, которые `listCalendars()` (К7) отображает без изменений.
struct RawCalendar: Sendable, Equatable {
    let calendarId: String
    let title: String
    let isReadOnly: Bool
}

/// Участник события — сырые (НЕ нормализованные) поля источника.
struct RawPerson: Sendable, Equatable {
    let name: String?
    /// Как отдаёт источник: может быть смешанного регистра и/или нести префикс `mailto:`
    /// (EventKit отдаёт адрес участника через `EKParticipant.url`, схема `mailto:`) —
    /// нормализация (К10) — обязанность коннектора, не шва.
    let email: String?
}

enum RawResponseStatus: Sendable, Equatable {
    case accepted, declined, tentative, needsAction, unknown
}

struct RawAttendee: Sendable, Equatable {
    let person: RawPerson
    let responseStatus: RawResponseStatus
    let isOptional: Bool
}

/// Событие источника — сырые поля EventKit, ДО нормализации (email, часовой пояс, границы
/// «весь день», `conference`) — ту делает коннектор (IR-116), не шов (перечень, раздел «Шов»).
struct RawEvent: Sendable, Equatable {
    /// Календарь-владелец — окно `[from, to)` и фильтр `calendarIds` (К20, развилка Р9)
    /// проверяет коннектор по этому полю и по `start`, а не полагается на то, что шов уже
    /// отфильтровал точно: предикат `EKEventStore` фильтрует по пересечению интервала, не по
    /// началу события, — граница `[from, to)` контракта уже, чем гарантия предиката.
    let calendarId: String
    let externalId: String
    let icalUid: String?
    let title: String
    let start: Date
    let end: Date
    /// Идентификатор пояса, как его несёт источник — не обязательно валидный IANA (К12,
    /// гипотетический вход теста; реальный EventKit пояса IANA-именами отдаёт и так).
    let timeZoneIdentifier: String
    let isAllDay: Bool
    let isCancelled: Bool
    let organizer: RawPerson?
    let attendees: [RawAttendee]
    let location: String?
    let notes: String?
    let url: URL?
    let lastModified: Date
}

/// Шов модуля — по образцу `HardwareGateway` в `capture` (C-004/MEE-310 §«Шов»).
protocol EventKitGateway: Sendable {
    func calendars() async throws -> [RawCalendar]
    func events(from: Date, to: Date, calendarIds: [String]) async throws -> [RawEvent]
}
