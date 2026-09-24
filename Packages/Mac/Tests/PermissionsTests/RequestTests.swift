//  Критерии перечня MEE-74 на тотальность `request(_:)`: 7–14, 16, 18, 19, 74 и механические
//  половины 15 и 20. Вход — подставленный статус (шов 1.а); ответ пользователя на промпт задаёт
//  тест. «Промпта не показывает» проверяется механически: фейк считает показы, а критерий 47
//  закрывает символы.

import DomainCore
import Foundation
import XCTest
@testable import Permissions

final class RequestTests: XCTestCase {

    static let withSystemStatus: [PermissionKind] = [.microphone, .screenRecording, .calendars, .notifications,
                                                     .accessibility]

    // MARK: - 7, 8. .granted → .granted без промпта

    func test_c07_granted_returnsGranted_withoutPrompt() async {
        for kind in Self.withSystemStatus {
            let harness = PermissionsHarness([kind: .granted])
            let outcome = await harness.sut.request(kind)
            XCTAssertEqual(outcome, .granted, "\(kind)")
            XCTAssertEqual(harness.statuses.prompts, [], "\(kind): промпт не показан")
        }
    }

    func test_c08_systemAudio_grantedByNote_returnsGranted_notPromptOnUse() async {
        let harness = PermissionsHarness()
        await harness.sut.note(observed: .granted, for: .systemAudioRecording)
        let outcome = await harness.sut.request(.systemAudioRecording)
        XCTAssertEqual(outcome, .granted)
    }

    // MARK: - 9, 10, 11, 12, 16. Отказы → .cannotPrompt без промпта

    func test_c09_denied_returnsCannotPrompt_forAllSixKinds() async {
        for kind in Self.withSystemStatus {
            let harness = PermissionsHarness([kind: .denied])
            let outcome = await harness.sut.request(kind)
            XCTAssertEqual(outcome, .cannotPrompt, "\(kind)")
            XCTAssertEqual(harness.statuses.prompts, [])
        }
        let harness = PermissionsHarness()
        await harness.sut.note(observed: .denied, for: .systemAudioRecording)
        let outcome = await harness.sut.request(.systemAudioRecording)
        XCTAssertEqual(outcome, .cannotPrompt)
    }

    func test_c10_c11_restrictedAndUnavailable_returnCannotPrompt() async {
        for status in [PermissionStatus.restricted, .unavailable] {
            for kind in Self.withSystemStatus {
                let harness = PermissionsHarness([kind: status])
                let outcome = await harness.sut.request(kind)
                XCTAssertEqual(outcome, .cannotPrompt, "\(kind) при \(status)")
                XCTAssertEqual(harness.statuses.prompts, [])
            }
        }
    }

    func test_c12_systemAudio_deniedByNote_returnsCannotPrompt() async {
        let harness = PermissionsHarness()
        await harness.sut.note(observed: .denied, for: .systemAudioRecording)
        let outcome = await harness.sut.request(.systemAudioRecording)
        XCTAssertEqual(outcome, .cannotPrompt)
    }

    func test_c16_accessibility_deniedRestrictedUnavailable_returnCannotPrompt() async {
        for status in [PermissionStatus.denied, .restricted, .unavailable] {
            let harness = PermissionsHarness([.accessibility: status])
            let outcome = await harness.sut.request(.accessibility)
            XCTAssertEqual(outcome, .cannotPrompt, "\(status)")
            XCTAssertEqual(harness.statuses.prompts, [])
        }
    }

    // MARK: - 13. request не меняет статус на четырёх статусах

    func test_c13_requestDoesNotChangeStatus() async {
        for status in [PermissionStatus.granted, .denied, .restricted, .unavailable] {
            for kind in Self.withSystemStatus {
                let harness = PermissionsHarness([kind: status])
                _ = await harness.sut.request(kind)
                let after = await harness.sut.status(of: kind)
                XCTAssertEqual(after, status, "\(kind) при \(status)")
            }
        }
    }

    // MARK: - 14. Тотальность: 36 клеток, каждая — значение перечисления
    //
    // MEE-379 (аудит MEE-377, п.3): половина критерия «быстрее 500 мс» здесь была проверкой по
    // реальным часам без единой инжектируемой задержки в проверяемом пути — измеряла шум
    // планировщика гейтящего раннера, а не поведение SUT. Вынесена отдельным негейтящим
    // прогоном — `PerformanceTests.test_c14_c18_totalityCellsAnswerWithin500ms`.

    func test_c14_totality_everyCellAnswersValidOutcome() async {
        var answered = 0
        for kind in Self.withSystemStatus {
            for status in [PermissionStatus.notDetermined, .granted, .denied, .restricted, .unavailable, .unknown] {
                let harness = PermissionsHarness([kind: status])
                harness.statuses.answer(true, for: kind)
                let outcome = await harness.sut.request(kind)
                XCTAssertTrue([.granted, .denied, .cannotPrompt, .promptOnUse].contains(outcome),
                              "\(kind) при \(status)")
                answered += 1
            }
        }
        // Право на системный звук: три клетки подаются через note, три недостижимы по построению —
        // источник статуса для этого права порт не опрашивает (критерий 22 это и проверяет).
        for status in [PermissionStatus.unknown, .granted, .denied] {
            let harness = PermissionsHarness()
            await harness.sut.note(observed: status, for: .systemAudioRecording)
            let outcome = await harness.sut.request(.systemAudioRecording)
            XCTAssertTrue([.granted, .denied, .cannotPrompt, .promptOnUse].contains(outcome), "\(status)")
            answered += 1
        }
        XCTAssertEqual(answered, 33, "36 клеток минус три недостижимые")
    }

    // MARK: - 15, механическая половина. После промпта статус уже не .notDetermined

    func test_c15_mechanicalHalf_afterPrompt_statusIsNotNotDetermined() async {
        for (answer, expected) in [(true, PermissionRequestOutcome.granted), (false, .denied)] {
            for kind in [PermissionKind.microphone, .screenRecording, .calendars, .notifications] {
                let harness = PermissionsHarness([kind: .notDetermined])
                harness.statuses.answer(answer, for: kind)
                let outcome = await harness.sut.request(kind)
                XCTAssertEqual(outcome, expected, "\(kind)")
                let after = await harness.sut.status(of: kind)
                XCTAssertNotEqual(after, .notDetermined, "\(kind)")
                XCTAssertEqual(harness.statuses.prompts, [kind])
            }
        }
    }

    // MARK: - 18. Системный звук при .unknown → .promptOnUse, статус прежний
    //
    // MEE-379 (аудит MEE-377, п.3): половина «не позднее 500 мс» вынесена туда же, в
    // `PerformanceTests.test_c14_c18_totalityCellsAnswerWithin500ms` — тот же довод, что у К14.

    func test_c18_systemAudio_unknown_promptOnUse() async {
        for sut in [SystemPermissions(), PermissionsHarness().sut] {
            let outcome = await sut.request(.systemAudioRecording)
            XCTAssertEqual(outcome, .promptOnUse)
            let after = await sut.status(of: .systemAudioRecording)
            XCTAssertEqual(after, .unknown)
        }
    }

    // MARK: - 19. Права независимы

    func test_c19_requestChangesAtMostItsOwnKind() async {
        for target in PermissionKind.allCases {
            let harness = PermissionsHarness([.microphone: .notDetermined, .screenRecording: .notDetermined,
                                              .calendars: .notDetermined, .notifications: .notDetermined,
                                              .accessibility: .denied])
            for kind in PermissionKind.allCases {
                harness.statuses.answer(true, for: kind)
            }
            let before = await harness.sut.snapshot()
            _ = await harness.sut.request(target)
            let after = await harness.sut.snapshot()
            for kind in PermissionKind.allCases where kind != target {
                XCTAssertEqual(after.status(of: kind), before.status(of: kind), "\(kind) после request(\(target))")
            }
        }
    }

    // MARK: - 20, механическая половина. Два параллельных request — один опрос источника

    func test_c20_mechanicalHalf_parallelRequests_promptOnce_sameOutcome() async {
        let harness = PermissionsHarness([.microphone: .notDetermined])
        harness.statuses.answer(true, for: .microphone)
        // MEE-379 (аудит MEE-377, п.1): второй `request` заводится ТОЛЬКО когда первый реально
        // вошёл в `prompt(_:)` — явный gate вместо фикс. паузы, угадывавшей столкновение по
        // реальному времени.
        harness.statuses.holdPromptUntilReleased = true
        async let first = harness.sut.request(.microphone)
        await harness.statuses.awaitPromptStarted(.microphone)
        async let second = harness.sut.request(.microphone)
        harness.statuses.releasePrompt()
        let outcomes = await [first, second]
        XCTAssertEqual(outcomes, [.granted, .granted])
        XCTAssertEqual(harness.statuses.prompts, [.microphone], "промпт показан ровно один раз")
    }

    // MARK: - 74. Вызов не с главного актора возвращается тем же значением

    func test_c74_requestFromDetachedTask_matchesMainActor() async {
        let sut = SystemPermissions()
        for kind in [PermissionKind.accessibility, .systemAudioRecording] {
            let onMain = await MainActor.run { Task { await sut.request(kind) } }
            let detached = Task.detached { await sut.request(kind) }
            let main = await onMain.value
            let other = await detached.value
            XCTAssertEqual(main, other, "\(kind)")
        }
    }
}
