//  Оснастка тестов модуля `permissions`: фейки швов 1.а, 1.б и 2 перечня MEE-74 и сборка портов
//  на подставленных источниках.
//
//  Реализацию портов оснастка не подменяет: перевод исхода чтения, правила `request`, `note`,
//  `changes()`, счёт удержаний и события исполняет настоящий код модуля.

import DomainCore
import Foundation
import XCTest
@testable import Permissions

// MARK: - Шов 1.а: текущий статус и промпт

final class FakeStatusSource: StatusSource, @unchecked Sendable {

    private let lock = NSLock()
    private var statuses: [PermissionKind: PermissionStatus]
    private var answers: [PermissionKind: Bool] = [:]
    private var prompted: [PermissionKind] = []
    /// MEE-379 (аудит MEE-377, п.1): вместо фикс. паузы, угадывающей когда второй `request`
    /// столкнётся с первым, — явный gate. Когда `true`, `prompt(_:)` сигналит `promptStarted`
    /// (тест видит, что первый вызов реально ВОШЁЛ в промпт) и висит до `releasePrompt()`.
    /// Само хранилище — под замком: `releasePrompt()` (возврат РП 24.09 18:05) пишет его же
    /// поле конкурентно с чтением в `prompt(_:)`.
    private var storedHoldPromptUntilReleased = false
    var holdPromptUntilReleased: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storedHoldPromptUntilReleased }
        set { lock.lock(); storedHoldPromptUntilReleased = newValue; lock.unlock() }
    }
    private var startedKinds: Set<PermissionKind> = []
    private var promptStartedContinuations: [(PermissionKind, CheckedContinuation<Void, Never>)] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    init(_ statuses: [PermissionKind: PermissionStatus] = [:]) {
        self.statuses = statuses
    }

    /// Права, для которых был показан промпт, в порядке показа.
    var prompts: [PermissionKind] {
        lock.lock()
        defer { lock.unlock() }
        return prompted
    }

    /// Ждёт момента, когда `prompt(kind)` реально вызван (вошёл, не обязательно ответил) —
    /// сигнал «первый вызов стартовал», не оценка времени.
    func awaitPromptStarted(_ kind: PermissionKind) async {
        lock.lock()
        if startedKinds.contains(kind) { lock.unlock(); return }
        await withCheckedContinuation { continuation in
            promptStartedContinuations.append((kind, continuation))
            lock.unlock()
        }
    }

    /// Отпускает все вызовы `prompt(_:)`, повисшие на `holdPromptUntilReleased`, и сбрасывает
    /// сам флаг (возврат РП 24.09 18:05): при поломке склейки `request` следующий, отдельный
    /// вызов `prompt(_:)` не должен повиснуть повторно — тест обязан УПАСТЬ на утверждении,
    /// а не зависнуть до сторожа CI.
    func releasePrompt() {
        holdPromptUntilReleased = false
        lock.lock()
        let pending = releaseContinuations
        releaseContinuations = []
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }

    func set(_ status: PermissionStatus, for kind: PermissionKind) {
        lock.lock()
        defer { lock.unlock() }
        statuses[kind] = status
    }

    /// Чем ответит «пользователь» на промпт права.
    func answer(_ granted: Bool, for kind: PermissionKind) {
        lock.lock()
        defer { lock.unlock() }
        answers[kind] = granted
    }

    func status(of kind: PermissionKind) async -> PermissionStatus {
        current(kind)
    }

    func prompt(_ kind: PermissionKind) async -> Bool {
        markPromptStarted(kind)
        if holdPromptUntilReleased {
            await withCheckedContinuation { continuation in
                lock.lock(); releaseContinuations.append(continuation); lock.unlock()
            }
        }
        return recordPrompt(kind)
    }

    private func markPromptStarted(_ kind: PermissionKind) {
        lock.lock()
        startedKinds.insert(kind)
        let waiters = promptStartedContinuations.filter { $0.0 == kind }
        promptStartedContinuations.removeAll { $0.0 == kind }
        lock.unlock()
        for (_, continuation) in waiters { continuation.resume() }
    }

    private func current(_ kind: PermissionKind) -> PermissionStatus {
        lock.lock()
        defer { lock.unlock() }
        return statuses[kind] ?? .denied
    }

    private func recordPrompt(_ kind: PermissionKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        prompted.append(kind)
        let granted = answers[kind] ?? false
        statuses[kind] = granted ? .granted : .denied
        return granted
    }
}

// MARK: - Шов 1.б: исход системного чтения

final class FakeSystemReader: SystemReader, @unchecked Sendable {

    private let lock = NSLock()
    private var readings: [PermissionKind: SystemReading]
    private var answers: [PermissionKind: Bool] = [:]

    init(_ readings: [PermissionKind: SystemReading] = [:]) {
        self.readings = readings
    }

    func set(_ reading: SystemReading, for kind: PermissionKind) {
        lock.lock()
        defer { lock.unlock() }
        readings[kind] = reading
    }

    func answer(_ granted: Bool, for kind: PermissionKind) {
        lock.lock()
        defer { lock.unlock() }
        answers[kind] = granted
    }

    func read(_ kind: PermissionKind) async -> SystemReading {
        current(kind)
    }

    func prompt(_ kind: PermissionKind) async -> Bool {
        answer(for: kind)
    }

    private func answer(for kind: PermissionKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return answers[kind] ?? false
    }

    private func current(_ kind: PermissionKind) -> SystemReading {
        lock.lock()
        defer { lock.unlock() }
        return readings[kind] ?? .unreadable
    }
}

// MARK: - Шов 2: настройки, автозапуск, активация

final class FakeSettingsOpener: SettingsOpener, @unchecked Sendable {

    private let lock = NSLock()
    private var failing: Set<PermissionKind> = []
    private var openedKinds: [PermissionKind] = []

    var opened: [PermissionKind] {
        lock.lock()
        defer { lock.unlock() }
        return openedKinds
    }

    func fail(_ kinds: Set<PermissionKind>) {
        lock.lock()
        defer { lock.unlock() }
        failing = kinds
    }

    func open(_ kind: PermissionKind) async -> Bool {
        record(kind)
    }

    private func record(_ kind: PermissionKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        openedKinds.append(kind)
        return !failing.contains(kind)
    }
}

struct FakeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class FakeLoginItems: LoginItemRegistry, @unchecked Sendable {

    private let lock = NSLock()
    private var enabled = false
    private var failure: String?

    func fail(with message: String?) {
        lock.lock()
        defer { lock.unlock() }
        failure = message
    }

    func isEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure {
            throw FakeFailure(message: failure)
        }
        self.enabled = enabled
    }
}

final class FakeActivation: ActivationSource, @unchecked Sendable {

    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    func start(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
    }

    /// Приложение вернулось в активное состояние.
    func fire() {
        lock.lock()
        let current = handler
        lock.unlock()
        current?()
    }
}

// MARK: - Шов часов (MEE-379, возврат РП 24.09 18:05)

/// Часы под управлением теста — `checkedAt` снимка перестаёт зависеть от настоящего `Date()`
/// и реальных пауз (см. `PermissionsCore.Environment.now`).
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 0)) {
        current = start
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}

// MARK: - Порт прав на подставленных источниках

struct PermissionsHarness {

    let statuses: FakeStatusSource
    let settings = FakeSettingsOpener()
    let loginItems = FakeLoginItems()
    let activation = FakeActivation()
    let sut: SystemPermissions

    init(_ statuses: [PermissionKind: PermissionStatus] = [:], now: @escaping @Sendable () -> Date = Date.init) {
        self.statuses = FakeStatusSource(statuses)
        sut = SystemPermissions(environment: .init(rights: self.statuses, settings: settings,
                                                   loginItems: loginItems, activation: activation, now: now))
    }

    /// Порт со швом 1.б: исход чтения подставлен, перевод в статус — настоящий.
    static func reading(_ readings: [PermissionKind: SystemReading]) -> (reader: FakeSystemReader,
                                                                          sut: SystemPermissions) {
        let reader = FakeSystemReader(readings)
        let sut = SystemPermissions(environment: .init(rights: TranslatingStatusSource(reader: reader),
                                                       settings: FakeSettingsOpener(),
                                                       loginItems: FakeLoginItems(),
                                                       activation: FakeActivation()))
        return (reader, sut)
    }
}

// MARK: - Потоки

enum Streams {

    /// Прочитать до `count` элементов, но не дольше `seconds`.
    static func take<Element: Sendable>(_ stream: AsyncStream<Element>, _ count: Int,
                                        within seconds: TimeInterval = 2) async -> [Element] {
        let reader = Task { () -> [Element] in
            var collected: [Element] = []
            for await element in stream {
                collected.append(element)
                if collected.count >= count { break }
            }
            return collected
        }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            reader.cancel()
        }
        let result = await reader.value
        watchdog.cancel()
        return result
    }
}

/// Ждать условия не дольше `seconds`; возвращает, дождались ли.
func waitUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

/// Асинхронный двойник `waitUntil` — для условий, которые сами читаются `await` (актор), где
/// `Thread.sleep` внутри цикла держал бы поток вместо уступки планировщику. MEE-379 (возврат РП
/// 24.09 18:05): ограниченный опрос вместо угадывания по фиксированной паузе.
func waitUntilAsync(_ seconds: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

// MARK: - Исходники и продукт сборки модуля

struct SourceFile {
    let name: String
    let text: String
}

enum PermissionsSources {

    static func directory(_ relative: String, from file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }

    static func swiftFiles(in relative: String) throws -> [SourceFile] {
        let root = directory(relative)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        return try names.map { name in
            SourceFile(name: name, text: try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8))
        }
    }

    static func sources() throws -> [SourceFile] { try swiftFiles(in: "Sources/Permissions") }

    /// Объектные файлы таргета `Permissions` рядом с бандлом тестов: продукт `swift build`.
    static func objectFiles() throws -> [URL] {
        let products = Bundle(for: FakeHoldHandle.self).bundleURL.deletingLastPathComponent()
        let build = products.appendingPathComponent("Permissions.build")
        let names = try FileManager.default.contentsOfDirectory(atPath: build.path).filter { $0.hasSuffix(".o") }
        return names.sorted().map { build.appendingPathComponent($0) }
    }
}
