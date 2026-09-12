//  Вложенные типы C-001: Person, Attendee, Conference и ResponseStatus.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Инвариант, который проверяет вложенный тип, сообщается им самим: `type` в ошибке — имя
//  вложенного типа, `path` — путь от него. Композиции пути через границу вложенного типа
//  не происходит ни на одном из двух путей создания.

import Foundation

extension MeetingEvent {

    /// Человек: имя и нормализованный адрес.
    public struct Person: Codable, Equatable, Sendable, DomainValidatable {
        public let name: String?
        /// Нормализован: нижний регистр, без схемы `mailto:`.
        public let email: String?

        public init(name: String?, email: String?) throws {
            self.name = name
            self.email = email
            try validate()
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            name = try box.decodeIfPresent(String.self, forKey: .name)
            email = try box.decodeIfPresent(String.self, forKey: .email)
            try validate()
        }

        public func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encodeIfPresent(name, forKey: .name)
            try box.encodeIfPresent(email, forKey: .email)
        }

        public func validate() throws {
            let owner = DomainOwner(contract: "C-001", type: "MeetingEvent.Person")
            guard let email else { return }
            try owner.check(Person.isNormalized(email), 3, "email",
                            "адрес не в форме локальная-часть@домен: \(email)")
        }

        /// Инвариант 3: ровно один `@`, обе части непусты, нет пробельных и управляющих
        /// символов, нет префикса `mailto:`, значение равно своему нижнему регистру.
        /// Форма, а не доставимость: `a@b` инвариант проходит.
        static func isNormalized(_ email: String) -> Bool {
            guard !email.isEmpty, email == email.lowercased(), !email.hasPrefix("mailto:") else {
                return false
            }
            guard !email.unicodeScalars.contains(where: { $0.value <= 0x20 }) else { return false }
            let parts = email.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            return !parts[0].isEmpty && !parts[1].isEmpty
        }
    }

    /// Участник встречи.
    public struct Attendee: Codable, Equatable, Sendable, DomainValidatable {
        public let person: Person
        public let responseStatus: ResponseStatus
        public let isOptional: Bool

        public init(person: Person, responseStatus: ResponseStatus, isOptional: Bool) throws {
            self.person = person
            self.responseStatus = responseStatus
            self.isOptional = isOptional
            try validate()
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            person = try box.decode(Person.self, forKey: .person)
            responseStatus = try box.decode(ResponseStatus.self, forKey: .responseStatus)
            isOptional = try box.decode(Bool.self, forKey: .isOptional)
            try validate()
        }

        public func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(person, forKey: .person)
            try box.encode(responseStatus, forKey: .responseStatus)
            try box.encode(isOptional, forKey: .isOptional)
        }

        public func validate() throws {
            try person.validate()
        }
    }

    /// Ссылка на созвон.
    public struct Conference: Codable, Equatable, Sendable, DomainValidatable {
        /// Ключ из таблицы правил; незнакомый провайдер не повод терять событие.
        public let provider: String
        public let joinUrl: URL
        public let meetingId: String?
        public let passcode: String?

        public init(provider: String, joinUrl: URL, meetingId: String?, passcode: String?) throws {
            self.provider = provider
            self.joinUrl = joinUrl
            self.meetingId = meetingId
            self.passcode = passcode
            try validate()
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            provider = try box.decode(String.self, forKey: .provider)
            joinUrl = try box.decode(URL.self, forKey: .joinUrl)
            meetingId = try box.decodeIfPresent(String.self, forKey: .meetingId)
            passcode = try box.decodeIfPresent(String.self, forKey: .passcode)
            try validate()
        }

        public func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(provider, forKey: .provider)
            try box.encode(joinUrl, forKey: .joinUrl)
            try box.encodeIfPresent(meetingId, forKey: .meetingId)
            try box.encodeIfPresent(passcode, forKey: .passcode)
        }

        public func validate() throws {
            let owner = DomainOwner(contract: "C-001", type: "MeetingEvent.Conference")
            let isAbsoluteHTTPS = joinUrl.scheme?.lowercased() == "https" && joinUrl.host != nil
            try owner.check(isAbsoluteHTTPS, 5, "joinUrl", "не абсолютный URL со схемой https")
        }
    }
}

extension MeetingEvent.Attendee {

    /// Перечисление со случаем `unknown` (C-001 §0.3): неизвестное значение читается как
    /// `.unknown` и при обратной записи теряется — исходная строка не сохраняется.
    public enum ResponseStatus: String, Codable, Sendable {
        case accepted
        case declined
        case tentative
        case needsAction
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = ResponseStatus(rawValue: raw) ?? .unknown
        }
    }
}

extension MeetingEvent.Person {
    enum CodingKeys: String, CodingKey {
        case name, email
    }
}

extension MeetingEvent.Attendee {
    enum CodingKeys: String, CodingKey {
        case person, responseStatus, isOptional
    }
}

extension MeetingEvent.Conference {
    enum CodingKeys: String, CodingKey {
        case provider, joinUrl, meetingId, passcode
    }
}
