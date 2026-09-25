//  AppFacadeImpl — permissionsReady (C-016 v10, группа К плана MEE-410; К31, К32). Разведено
//  из `AppFacadeImpl.swift` по объёму (`file_length`), не по смыслу.
//
//  Модуль: domain-core · Владелец: DEV-1 (в помощь MEE-420) · Слой: домен
//
//  MEE-437: заголовок `AppFacadeImpl.swift` называл эту группу «уже существующей
//  инфраструктурой» — на деле вычисления не было вовсе, `status()` отдавал `.notReady`
//  литералом (сам же заголовок файла это честно объявлял: «предмет своей, ещё не сделанной
//  группы К»). Этот файл — сама группа К, не только её тест.

import Foundation

extension AppFacadeImpl {

    /// К31 (инв. 25): обязательность права по `PermissionKind` и действующей политике записи.
    /// Исчерпывающий `switch` без `default:` — «правило тотальности» (право, не названное
    /// явно ни в одной из трёх групп, обязательно) исполнено здесь компилятором буквально:
    /// новый `PermissionKind` не скомпилируется, пока кто-то не отнесёт его к одной из трёх
    /// веток, а не тихо получит какое-то умолчание во время исполнения.
    func isPermissionRequired(_ kind: PermissionKind, settings: AppSettings) -> Bool {
        switch kind {
        case .microphone, .systemAudioRecording:
            return true
        case .notifications:
            return settings.recordingPolicy == .ask
        case .screenRecording, .calendars, .accessibility:
            return false
        }
    }

    /// К32 (инв. 26), мех.-половина: `switch` по `PermissionStatus` без `default:` — тот же
    /// приём тотальности, что у `isPermissionRequired`.
    private func readinessBucket(for status: PermissionStatus) -> PermissionsReadinessBucket {
        switch status {
        case .notDetermined, .denied, .restricted, .unavailable:
            return .blocking
        case .unknown:
            return .pending
        case .granted:
            return .ready
        }
    }

    /// К31/К32: ступени в порядке (а)→(б)→(в) — хотя бы одно блокирующее обязательное право
    /// перевешивает «неизвестное», а «неизвестное» перевешивает «готово».
    func permissionsReady(snapshot: PermissionSnapshot, settings: AppSettings) -> PermissionsReadiness {
        let buckets = PermissionKind.allCases
            .filter { isPermissionRequired($0, settings: settings) }
            .map { readinessBucket(for: snapshot.status(of: $0)) }
        if buckets.contains(.blocking) { return .notReady }
        if buckets.contains(.pending) { return .unknownUntilFirstUse }
        return .ready
    }
}

private enum PermissionsReadinessBucket {
    case blocking
    case pending
    case ready
}
