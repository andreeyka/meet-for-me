//  StatusTranslation — исход системного чтения → `PermissionStatus`. Чистая функция; предмет
//  проверки критериев 17 и 21 (шов 1.б).
//
//  Правила, которых контракт не называет и которые выбраны здесь (цена названа в отчёте
//  по MEE-66):
//
//  * «чтение не удалось» и исход чужого права → `.unavailable`. Не `.unknown` — его порт для
//    прав с публичным статусом не производит никогда (инвариант 11); не `.denied` и не
//    `.restricted` — утверждения о пользователе и о политике, которых никто не делал; не
//    `.notDetermined` — обещало бы промпт (инвариант 6), которого нечем показать, и запрещено
//    праву «Универсальный доступ» (инвариант 5);
//  * `.screenRecording`: публичный вызов отдаёт только `Bool`, различить «не спрашивали»
//    и «отказано» нечем. Пока в этом запуске порт промпт не показывал — `.notDetermined`;
//    после показа — `.denied`, чтобы инвариант 6 исполнялся: статус после `request` уже
//    не `.notDetermined`. Расхождение с системой названо запросом (номер за РП);
//  * `.calendars` с доступом «только добавление» → `.denied`: полного доступа, который нужен
//    коннектору, нет, а повторный промпт на повышение доступа не измерен;
//  * `.notifications` с временным (`provisional`) доступом → `.granted`: уведомления доставляются.

import AVFoundation
import DomainCore
import EventKit
import UserNotifications

enum StatusTranslation {

    static func status(of kind: PermissionKind, reading: SystemReading,
                       promptedThisLaunch: Bool) -> PermissionStatus {
        switch (kind, reading) {
        case (.microphone, .microphone(let value)):
            return microphone(value)
        case (.screenRecording, .screenRecording(let granted)):
            return granted ? .granted : (promptedThisLaunch ? .denied : .notDetermined)
        case (.calendars, .calendars(let value)):
            return calendars(value)
        case (.notifications, .notifications(let value)):
            return notifications(value)
        case (.accessibility, .accessibility(let trusted)):
            return trusted ? .granted : .denied
        default:
            return .unavailable
        }
    }

    private static func microphone(_ value: AVAuthorizationStatus) -> PermissionStatus {
        switch value {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .granted
        @unknown default: return .unavailable
        }
    }

    private static func calendars(_ value: EKAuthorizationStatus) -> PermissionStatus {
        switch value {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess, .authorized: return .granted
        case .writeOnly: return .denied
        @unknown default: return .unavailable
        }
    }

    private static func notifications(_ value: UNAuthorizationStatus) -> PermissionStatus {
        switch value {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional: return .granted
        @unknown default: return .unavailable
        }
    }
}
