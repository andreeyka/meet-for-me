//  Критерии 31.б и 32 перечня MEE-74: на диск не записано ничего — поведенчески, по следам.
//
//  Снимок файловой системы: имена и `mtime` в `~/Library/Preferences`, `~/Library/Application
//  Support`, `~/Library/Caches` и во временном каталоге (в глубину до двух уровней — новый файл
//  меняет `mtime` своего каталога) плюс полный словарь настроек процесса. Соседние процессы того же
//  пользователя тоже пишут туда; поэтому прогонов до трёх, а совпадение засчитывается по любому:
//  запись модуля повторилась бы в каждом.

import DomainCore
import Foundation
import XCTest
@testable import Permissions

final class DiskFootprintTests: XCTestCase {

    struct Footprint: Equatable {
        let files: [String: Date]
        let defaults: [String: String]

        static func take() -> Footprint {
            let home = FileManager.default.homeDirectoryForCurrentUser
            var roots = ["Library/Preferences", "Library/Application Support", "Library/Caches"]
                .map { home.appendingPathComponent($0) }
            roots.append(URL(fileURLWithPath: NSTemporaryDirectory()))
            var files: [String: Date] = [:]
            for root in roots {
                walk(root, depth: 2, into: &files)
            }
            let defaults = UserDefaults.standard.dictionaryRepresentation().mapValues { String(describing: $0) }
            return Footprint(files: files, defaults: defaults)
        }

        private static func walk(_ url: URL, depth: Int, into files: inout [String: Date]) {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
            let manager = FileManager.default
            guard let entries = try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                 options: []) else { return }
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: Set(keys))
                files[entry.path] = values?.contentModificationDate ?? .distantPast
                if depth > 1, values?.isDirectory == true {
                    walk(entry, depth: depth - 1, into: &files)
                }
            }
        }

        func difference(from other: Footprint) -> [String] {
            let changedFiles = Set(files.keys).union(other.files.keys).filter { files[$0] != other.files[$0] }
            let changedKeys = Set(defaults.keys).union(other.defaults.keys).filter { defaults[$0] != other.defaults[$0] }
            return changedFiles.sorted() + changedKeys.sorted().map { "defaults: \($0)" }
        }
    }

    /// До трёх попыток: совпавшие снимки означают, что записи не было.
    private func assertNoFootprint(_ body: (SystemPermissions) async -> Void) async {
        var differences: [[String]] = []
        for _ in 0..<3 {
            let before = Footprint.take()
            let harness = PermissionsHarness()
            await body(harness.sut)
            let after = Footprint.take()
            let difference = after.difference(from: before)
            if difference.isEmpty { return }
            differences.append(difference)
        }
        XCTFail("след на диске в каждой из трёх попыток: \(differences)")
    }

    // MARK: - 31.б. После note(.granted) снимки совпадают

    func test_c31b_noteLeavesNoFootprint() async {
        await assertNoFootprint { sut in
            await sut.note(observed: .granted, for: .systemAudioRecording)
            _ = await sut.snapshot()
        }
    }

    // MARK: - 32. После недопустимых note снимки совпадают

    func test_c32_invalidNotesLeaveNoFootprint() async {
        await assertNoFootprint { sut in
            for kind in PermissionKind.allCases where kind != .systemAudioRecording {
                await sut.note(observed: .granted, for: kind)
            }
            for value in [PermissionStatus.notDetermined, .restricted, .unavailable, .unknown] {
                await sut.note(observed: value, for: .systemAudioRecording)
            }
        }
    }
}
