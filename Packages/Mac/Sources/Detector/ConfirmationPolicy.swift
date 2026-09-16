//  ConfirmationPolicy — когда порт подтверждает держащееся состояние. C-009, инвариант 24.
//
//  Путь, на котором решается срок подтверждения, живёт в этом файле целиком, и срок в нём не
//  написан ни одним числом секунд: он выводится из `signalTtlSeconds`, пришедшего в точку
//  приёма Ш5. Контракт называет только верхнюю границу — «разрыв меньше срока», — а запас
//  оставляет реализации. Запас здесь назван, и тест его наблюдает (Ш6 (iii)):
//
//  * пара «вид + источник» подтверждается на первом шаге наблюдения, на котором с её прошлой
//    публикации прошло не меньше ПОЛОВИНЫ срока (`confirmationShare`);
//  * шаг наблюдения не длиннее ЧЕТВЕРТИ срока (`longestStepShare`).
//
//  Отсюда граница, которая и есть инвариант 24: разрыв между публикациями одной пары не
//  больше половины срока плюс один шаг — то есть не больше трёх четвертей срока, строго
//  меньше `signalTtlSeconds`, — при шаге, который наблюдение действительно выдерживает.

import Foundation

enum ConfirmationPolicy {

    /// Доля срока, после которой держащееся состояние подтверждается публикацией.
    static let confirmationShare = 0.5

    /// Наибольшая доля срока, которую может занять один шаг наблюдения.
    static let longestStepShare = 0.25

    /// Возраст прошлой публикации пары, начиная с которого она подтверждается.
    static func confirmationAge(signalTtlSeconds: Double) -> TimeInterval {
        signalTtlSeconds * confirmationShare
    }

    /// Шаг наблюдения: предпочтительный, но не длиннее доли срока.
    static func step(preferred: TimeInterval, signalTtlSeconds: Double) -> TimeInterval {
        min(preferred, signalTtlSeconds * longestStepShare)
    }

    /// Пора ли подтверждать пару, опубликованную в `published`, в момент `now`.
    ///
    /// Часы, пошедшие назад, подтверждение не откладывают: возраст меньше нуля — тоже «пора».
    /// Иначе перевод часов машины назад растянул бы разрыв сверх срока.
    static func isDue(published: Date, now: Date, signalTtlSeconds: Double) -> Bool {
        let age = now.timeIntervalSince(published)
        return age < 0 || age >= confirmationAge(signalTtlSeconds: signalTtlSeconds)
    }
}
