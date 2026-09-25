//  AppFacadeImpl — renamePerson (C-016 v10, группа Ф плана MEE-410; К46, MEE-441). Разведено
//  из `AppFacadeImpl.swift` по объёму (`file_length`), не по смыслу — та же причина, что у
//  соседних `AppFacadeImpl+*.swift`.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import Foundation

extension AppFacadeImpl {

    /// К46 («Протокол» §4, `renamePerson` — не назван ни одним отдельным инвариантом 1-28 и
    /// ничем сверх голой сигнатуры протокола, возврат РП п.6): сквозная обёртка над
    /// `PersonRepository.rename(personId:displayName:)` — второго места переименовать
    /// человека в домене нет. Отказ на несуществующем `personId` пробрасывается как есть
    /// (`PersonRepository` C-010, `notFound` — тот же словарь §3.1, что и остальные методы).
    ///
    /// Событие — инв. 15 (критерий проверяет только сам факт публикации, не то, какое именно
    /// из пяти — контракт не называет ни одного для `renamePerson`, см. К46). `.meetingsChanged`
    /// выбран как наименее произвольный из пяти: список встреч (`MeetingListItem`/`MeetingDetail`)
    /// способен показывать имя организатора/участника, а `renamePerson` меняет ровно это поле
    /// где-то в домене — тот же довод, что уже применён к `syncCalendars()`/К33.
    public func renamePerson(personId: UUID, displayName: String) async throws {
        do {
            try await persons.rename(personId: personId, displayName: displayName)
            publish(.meetingsChanged)
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
    }
}
