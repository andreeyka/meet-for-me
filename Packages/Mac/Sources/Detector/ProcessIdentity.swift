//  ProcessIdentity — кто такой процесс: имя исполняемого файла, ответственный процесс и bundle id
//  приложения, которому процесс принадлежит.
//
//  C-009 «Опора на приватный API»: ответственный процесс разрешается приватным символом
//  `responsibility_get_pid_responsible_for_pid` через `dlsym`. Разрешение решено РП для Среза 1
//  (вердикт по MEE-8). Цена названа контрактом: символ может не разрешиться на будущей macOS.
//  Деградация тогда такая и только такая: ответственный процесс не определён ни у одного
//  процесса снимка (инвариант 20), правило §4.1 работает одним шагом 2, Chrome распознаётся,
//  Safari — нет, ложного совпадения не появляется.

import Darwin
import Foundation

enum ProcessIdentity {

    typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t

    /// Имя приватного символа libsystem.
    static let responsibilitySymbolName = "responsibility_get_pid_responsible_for_pid"

    /// Функция ответственного процесса; `nil`, если символ на этой системе не разрешился.
    static let responsibleFunction: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), responsibilitySymbolName) else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    /// Ответственный процесс; `nil`, если символа нет или вызов не дал процесса.
    static func responsiblePid(of pid: Int32) -> Int32? {
        guard let function = responsibleFunction else { return nil }
        let responsible = function(pid)
        return responsible > 0 ? responsible : nil
    }

    /// Путь исполняемого файла процесса; `nil`, если система его не отдала.
    static func executablePath(ofPid pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Имя исполняемого файла; пустая строка, если путь недоступен.
    static func executableName(ofPid pid: Int32) -> String {
        guard let path = executablePath(ofPid: pid) else { return "" }
        return (path as NSString).lastPathComponent
    }

    /// Bundle id ближайшего объемлющего бандла приложения (`.app`, `.appex`, `.xpc`) процесса.
    static func bundleIdentifier(ofPid pid: Int32) -> String? {
        guard var directory = executablePath(ofPid: pid) as NSString? else { return nil }
        while directory.length > 1 {
            directory = directory.deletingLastPathComponent as NSString
            if ["app", "appex", "xpc"].contains(directory.pathExtension) {
                return Bundle(path: directory as String)?.bundleIdentifier
            }
        }
        return nil
    }
}
