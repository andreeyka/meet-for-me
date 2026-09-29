//  InMemoryMeetingRepository — подключение связей «встреча → люди» (C-010 v27, инв. 36;
//  MEE-460). Деление по объёму (`file_length` основного файла), не по смыслу.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)

import Foundation
import DomainCore

extension InMemoryMeetingRepository {

    /// Зовёт контейнер `InMemoryRepositories` — единственный вызывающий, наружу поверхности
    /// не несёт (тот же приём, что `attachCascade(recordings:)`).
    func attachPersons(_ persons: InMemoryPersonRepository) {
        self.persons = persons
    }
}
