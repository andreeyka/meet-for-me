//  Пп. 136—141: инварианты, добавленные изданием C-002 v4, и отсутствие ловушки Int(_: Double).

import XCTest
import DomainCore
import DomainTestKit

final class ManifestV4Tests: XCTestCase {

    private let farDate = Date(timeIntervalSince1970: 9_400_000_000_000)

    /// Вектор Q24. На пути из JSON он невыразим: `startedAt` вне диапазона отсекает
    /// грамматика `Date` при разборе, — а значит без него падение не воспроизводит ни один тест.
    func test_p136_noIntTrap_startedAt() throws {
        assertInvariant(try DateProbe.manifest(startedAt: farDate),
                        contract: "C-002", type: "RecordingManifest", invariant: 0,
                        path: "startedAt")
    }

    func test_p136_noIntTrap_endedAt() throws {
        assertInvariant(try DateProbe.manifest(endedAt: farDate),
                        contract: "C-002", type: "RecordingManifest", invariant: 0,
                        path: "endedAt")
    }

    func test_p137_discontinuityNonNegativity() throws {
        for (value, path) in [("-1", "atMs"), ("-1", "gapMs"), ("-1", "scaleErrorMs")] {
            let gap = ManifestJSON.gap(
                atMs: path == "atMs" ? value : "0",
                gapMs: path == "gapMs" ? value : "0",
                scaleErrorMs: path == "scaleErrorMs" ? value : "0")
            assertInvariant(try decodeManifest(ManifestJSON.text(
                markers: "[\(ManifestJSON.marker(kind: "\"discontinuity\"", atMs: "0"))]",
                discontinuities: "[\(gap)]")),
                contract: "C-002", type: "RecordingManifest.Discontinuity", invariant: 14,
                path: path)
        }
    }

    func test_p137_discontinuitySorting() throws {
        let markers = [0, 30, 40, 50]
            .map { ManifestJSON.marker(kind: "\"discontinuity\"", atMs: "\($0)") }
            .joined(separator: ", ")
        let gaps = [0, 50, 40, 30].map { ManifestJSON.gap(atMs: "\($0)") }.joined(separator: ", ")
        assertInvariant(try decodeManifest(ManifestJSON.text(markers: "[\(markers)]",
                                                             discontinuities: "[\(gaps)]")),
                        contract: "C-002", type: "RecordingManifest", invariant: 14,
                        path: "discontinuities[2].atMs")
    }

    /// Пара «нестрогий инв. 14 против строгого инв. 9» в одном тесте.
    func test_p137_equalDiscontinuityTimesAreAccepted() throws {
        let markers = "[\(ManifestJSON.marker(kind: "\"discontinuity\"", atMs: "500")), " +
            "\(ManifestJSON.marker(kind: "\"discontinuity\"", atMs: "500"))]"
        let gaps = "[\(ManifestJSON.gap(atMs: "500")), " +
            "\(ManifestJSON.gap(atMs: "500", reason: "\"sleep\""))]"
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(markers: markers,
                                                              discontinuities: gaps)))
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(discontinuities: "[]")))
        let spans = "[\(ManifestJSON.span(atMs: "0")), \(ManifestJSON.span(atMs: "0"))]"
        XCTAssertEqual(errorFields(try decodeManifest(ManifestJSON.text(inputDevices: spans)))?
                        .invariant, 9)
    }

    /// Инвариант 15 считает кратность, а не наличие.
    func test_p138_multiplicityNotPresence() throws {
        let twoMarkers = "[\(ManifestJSON.marker(kind: "\"discontinuity\"", atMs: "500")), " +
            "\(ManifestJSON.marker(kind: "\"discontinuity\"", atMs: "500"))]"
        let oneGap = "[\(ManifestJSON.gap(atMs: "500"))]"
        assertInvariant(try decodeManifest(ManifestJSON.text(markers: twoMarkers,
                                                             discontinuities: oneGap)),
                        contract: "C-002", type: "RecordingManifest", invariant: 15,
                        path: "markers[0].atMs")
        let oneMarker = "[\(ManifestJSON.marker(kind: "\"discontinuity\"", atMs: "500"))]"
        let twoGaps = "[\(ManifestJSON.gap(atMs: "500")), \(ManifestJSON.gap(atMs: "500"))]"
        assertInvariant(try decodeManifest(ManifestJSON.text(markers: oneMarker,
                                                             discontinuities: twoGaps)),
                        contract: "C-002", type: "RecordingManifest", invariant: 15,
                        path: "markers[0].atMs")
        assertInvariant(try decodeManifest(ManifestJSON.text(markers: oneMarker,
                                                             discontinuities: "[]")),
                        contract: "C-002", type: "RecordingManifest", invariant: 15,
                        path: "markers[0].atMs")
        let pairedPlusOrphan = "[\(ManifestJSON.gap(atMs: "500")), \(ManifestJSON.gap(atMs: "900"))]"
        assertInvariant(try decodeManifest(ManifestJSON.text(markers: oneMarker,
                                                             discontinuities: pairedPlusOrphan)),
                        contract: "C-002", type: "RecordingManifest", invariant: 15,
                        path: "discontinuities[1].atMs")
    }

    /// Различие с инв. 10, который биекцией не является: тот же по форме дубль там принят.
    func test_p138_differenceWithInvariantTen() throws {
        let twoMarkers = "[\(ManifestJSON.marker(kind: "\"discontinuity\"", atMs: "500")), " +
            "\(ManifestJSON.marker(kind: "\"discontinuity\"", atMs: "500"))]"
        let twoGaps = "[\(ManifestJSON.gap(atMs: "500")), \(ManifestJSON.gap(atMs: "500"))]"
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(markers: twoMarkers,
                                                              discontinuities: twoGaps)))
        let spans = "[\(ManifestJSON.span(atMs: "0")), \(ManifestJSON.span(atMs: "500"))]"
        let doubleChange = "[\(ManifestJSON.marker(kind: "\"deviceChanged\"", atMs: "500")), " +
            "\(ManifestJSON.marker(kind: "\"deviceChanged\"", atMs: "500"))]"
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(markers: doubleChange,
                                                              inputDevices: spans)))
    }

    func test_p139_emptyStringIsNotAValue_sixFields() throws {
        assertInvariant(try RecordingManifest.Marker(kind: .pause, atMs: 0, detail: ""),
                        contract: "C-002", type: "RecordingManifest.Marker", invariant: 16,
                        path: "detail")
        assertInvariant(try RecordingManifest.CapturedProcess(pid: 1, bundleId: "",
                                                              executableName: nil),
                        contract: "C-002", type: "RecordingManifest.CapturedProcess",
                        invariant: 16, path: "bundleId")
        assertInvariant(try RecordingManifest.CapturedProcess(pid: 1, bundleId: nil,
                                                              executableName: ""),
                        contract: "C-002", type: "RecordingManifest.CapturedProcess",
                        invariant: 16, path: "executableName")
        assertInvariant(try RecordingManifest.InputDeviceSpan(atMs: 0, present: true,
                                                              name: "", uid: nil),
                        contract: "C-002", type: "RecordingManifest.InputDeviceSpan",
                        invariant: 16, path: "name")
        assertInvariant(try RecordingManifest.InputDeviceSpan(atMs: 0, present: true,
                                                              name: nil, uid: ""),
                        contract: "C-002", type: "RecordingManifest.InputDeviceSpan",
                        invariant: 16, path: "uid")
        assertInvariant(try ManifestProbe.manifest(violation: .emptyCaptureGroupKey),
                        contract: "C-002", type: "RecordingManifest", invariant: 16,
                        path: "captureGroupKey")
    }

    /// Пара «`nil` принят — `""` отвергнут» на каждом поле, и рядом — `title == ""` C-001,
    /// принятое по-прежнему: разные контракты, разные правила.
    func test_p139_nilIsAcceptedAndTitleStaysEmptyFriendly() throws {
        XCTAssertNoThrow(try RecordingManifest.Marker(kind: .pause, atMs: 0, detail: nil))
        XCTAssertNoThrow(try RecordingManifest.Marker(kind: .pause, atMs: 0, detail: "x"))
        XCTAssertNoThrow(try RecordingManifest.CapturedProcess(pid: 1, bundleId: nil,
                                                               executableName: nil))
        XCTAssertNoThrow(try RecordingManifest.InputDeviceSpan(atMs: 0, present: true,
                                                               name: nil, uid: nil))
        XCTAssertNoThrow(try decodeEvent(EventJSON.text(title: "\"\"")))
    }

    func test_p140_absentDeviceCannotBeNamed() throws {
        assertInvariant(try RecordingManifest.InputDeviceSpan(atMs: 0, present: false,
                                                              name: "MacBook Pro Microphone",
                                                              uid: nil),
                        contract: "C-002", type: "RecordingManifest.InputDeviceSpan",
                        invariant: 17, path: "name")
        assertInvariant(try RecordingManifest.InputDeviceSpan(atMs: 0, present: false,
                                                              name: nil, uid: "A1B2C3"),
                        contract: "C-002", type: "RecordingManifest.InputDeviceSpan",
                        invariant: 17, path: "uid")
        XCTAssertNoThrow(try RecordingManifest.InputDeviceSpan(atMs: 0, present: false,
                                                               name: nil, uid: nil))
        XCTAssertNoThrow(try RecordingManifest.InputDeviceSpan(atMs: 0, present: true,
                                                               name: nil, uid: nil))
        XCTAssertNoThrow(try RecordingManifest.InputDeviceSpan(atMs: 0, present: true,
                                                               name: "MacBook", uid: "A1B2C3"))
    }

    /// Инвариант 18 не отвечает ни на одном входе: разрыв за `durationMs` требует парного
    /// маркера (инв. 15), а такой маркер нарушает инв. 11 — номер меньше, и отвечает он.
    /// Отчёт по задаче называет это находкой; здесь фиксируется достижимый ответ.
    func test_p141_discontinuityBeyondDurationAnswersByInvariantEleven() throws {
        let markers = "[\(ManifestJSON.marker(kind: "\"discontinuity\"", atMs: "3600001"))]"
        let gaps = "[\(ManifestJSON.gap(atMs: "3600001"))]"
        assertInvariant(try decodeManifest(ManifestJSON.text(markers: markers,
                                                             discontinuities: gaps)),
                        contract: "C-002", type: "RecordingManifest", invariant: 11,
                        path: "markers[0].atMs")
        let orphan = try decodeManifestOrError(ManifestJSON.text(markers: "[]",
                                                                 discontinuities: gaps))
        XCTAssertEqual(orphan?.invariant, 15)
    }

    func test_p141_discontinuityAtDurationIsAccepted() throws {
        let markers = "[\(ManifestJSON.marker(kind: "\"discontinuity\"", atMs: "3600000"))]"
        let gaps = "[\(ManifestJSON.gap(atMs: "3600000"))]"
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(markers: markers,
                                                              discontinuities: gaps)))
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            endedAt: "null",
            markers: "[\(ManifestJSON.marker(kind: "\"discontinuity\"", atMs: "999999999"))]",
            discontinuities: "[\(ManifestJSON.gap(atMs: "999999999"))]",
            isFinalized: "false")))
    }

    /// Оборванная запись — принимающий вектор: последний разрыв стоит ровно на `durationMs`.
    func test_p141_truncatedFixtureIsValid() throws {
        XCTAssertNoThrow(try RecordingManifestFixtures.truncatedRecovered.validate())
    }

    private func decodeManifestOrError(_ text: String) throws -> ErrorFields? {
        errorFields(try decodeManifest(text))
    }
}
