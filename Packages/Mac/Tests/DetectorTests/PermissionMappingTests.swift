//  Критерии блока F перечня MEE-75: отказ по праву. К54, К56.
//
//  К54 проверяет ФОРМУ отображения (шов Ш3) — тотальность и то, что неизвестный код не даёт
//  отказа по праву никогда. Ключ, названный признаком, — догадка реализации до ручного
//  прогона Р1: код отказа по праву не наблюдал никто.
//  К56 закрывает половину «тогда»: пока системные вызовы возвращают 0, отказа по праву нет.
//  Половина «только тогда» в CI не проверяется ничем — настоящего отказа на раннере не бывает.

import CoreAudio
import DomainCore
import Foundation
import XCTest
@testable import Detector

final class PermissionMappingTests: XCTestCase {

    func test_k54_mapping_isTotal_andUnknownCodeNeverMeansPermission() {
        XCTAssertNil(HALStatusMapping.error(for: 0, call: "probe", data: .systemAudioRecording))
        let recognised = HALStatusMapping.permissionDeniedStatus
        XCTAssertEqual(HALStatusMapping.error(for: recognised, call: "probe", data: .systemAudioRecording),
                       .permissionRequired(.systemAudioRecording))
        XCTAssertEqual(HALStatusMapping.error(for: recognised, call: "probe", data: .microphone),
                       .permissionRequired(.microphone))
        let others = [kAudioHardwareBadObjectError, kAudioHardwareUnspecifiedError, 12_345, -1, .max, .min]
        for status in others where status != recognised {
            guard case .systemUnavailable = HALStatusMapping.error(for: status, call: "probe", data: .microphone) else {
                return XCTFail("код \(status) обязан давать systemUnavailable")
            }
        }
        for status in stride(from: Int32(-70_000), through: 70_000, by: 97) where status != 0 && status != recognised {
            XCTAssertNotNil(HALStatusMapping.error(for: status, call: "sweep", data: .systemAudioRecording))
            XCTAssertNotEqual(HALStatusMapping.error(for: status, call: "sweep", data: .systemAudioRecording),
                              .permissionRequired(.systemAudioRecording))
        }
    }

    func test_k56_liveRunner_noPermissionRefusalWhileCallsSucceed() async throws {
        let journal = StatusJournal()
        let environment = SignalEngine.Environment(source: HALProcessSource(journal: journal), clock: SystemClock(),
                                                   driver: ManualDriver(), preferredStep: Harness.preferredStep)
        let detector = MeetingDetector(tables: try RuleTables.shipped.get(),
                                       values: try ReferenceTables.shippedValues(), environment: environment)
        var refusal: ProcessMonitorError?
        do {
            _ = try await detector.audioProcesses()
            try await detector.startObserving()
            await detector.stopObserving()
        } catch let error as ProcessMonitorError {
            refusal = error
        }
        XCTAssertFalse(journal.all.isEmpty, "коды возврата записаны")
        if case .permissionRequired = refusal {
            XCTAssertTrue(journal.all.contains { $0.status == HALStatusMapping.permissionDeniedStatus },
                          "отказ по праву брошен только при признанном коде")
        } else {
            XCTAssertFalse(journal.all.contains { $0.status == HALStatusMapping.permissionDeniedStatus })
        }
    }
}
