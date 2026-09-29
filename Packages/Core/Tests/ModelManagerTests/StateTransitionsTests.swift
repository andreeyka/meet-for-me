//  К46, К49 перечня MEE-429 (план MEE-436, группа Н): переходы `ModelState` наблюдаются только
//  через `events()` (подписка до прогона) и сверяются со списком инварианта 6; `stateChanged`
//  публикуется на `beginUse`/`endUse` и на загрузке (§4.1, «Поведение»).

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

final class StateTransitionsTests: XCTestCase {

    /// Инвариант 6 дословно: допустимые переходы по именам случаев.
    static let allowed: Set<String> = [
        "available→downloading",
        "downloading→downloaded", "downloading→paused", "downloading→available", "downloading→error",
        "paused→downloading", "paused→available",
        "downloaded→loaded", "downloaded→available", "downloaded→error",
        "loaded→downloaded",
        "error→downloading", "error→available",
    ]

    static func name(_ state: ModelState) -> String {
        switch state {
        case .available: return "available"
        case .downloading: return "downloading"
        case .paused: return "paused"
        case .downloaded: return "downloaded"
        case .loaded: return "loaded"
        case .error: return "error"
        }
    }

    /// Последовательность переходов по событиям модели, начиная с состояния до подписки.
    /// Повтор `downloading → downloading` (рост `fraction`) — не переход между случаями.
    static func transitions(from initial: ModelState, _ states: [ModelState]) -> [String] {
        var result: [String] = []
        var current = name(initial)
        for state in states.map(name) where state != current {
            result.append("\(current)→\(state)")
            current = state
        }
        return result
    }

    func test_k46_observedTransitionsSubsetOfInvariant6PlusThreeForbiddenInputs() async throws {
        var observed = Set<String>()
        for scenario in Self.scenarios {
            let run = try await scenario()
            XCTAssertFalse(run.transitions.isEmpty, "вектор непустоты: прогон «\(run.name)» дал переходы")
            observed.formUnion(run.transitions)
            for transition in run.transitions {
                XCTAssertTrue(Self.allowed.contains(transition), "«\(run.name)»: \(transition) вне инв. 6")
            }
        }
        XCTAssertEqual(observed, Self.allowed, "прогоны К17/К22/К26/К32/К34/К47/К48 дают все переходы инв. 6")

        try await assertForbiddenInputsProduceNoTransition()
    }

    func test_k49_stateChangedExactlyOnceForLoadedAndDownloadedAtLeastOnceDownloadingDuringDownload()
        async throws {
        let model = TestModel.gigaamLike()
        let harness = ModelHarness(models: [model])
        let manager = try harness.makeManager()
        let recorder = EventRecorder(manager.events())
        let id = model.descriptor.id
        try await manager.download(id: id, version: "1.0.0")
        await recorder.settle { $0.count >= 2 }
        let downloadStates = recorder.states(of: id)
        XCTAssertTrue(downloadStates.contains { $0.isDownloading }, "хотя бы одно downloading(_)")
        XCTAssertEqual(downloadStates.last, .downloaded, "затем downloaded")
        XCTAssertEqual(downloadStates.filter { !$0.isDownloading }, [.downloaded])

        let useRecorder = EventRecorder(manager.events())
        let bundle = ModelBundle(modelId: id, version: "1.0.0", role: .asr, runtime: .onnx,
                                 directoryURL: harness.directory(model))
        let token = try await manager.beginUse([bundle])
        await manager.endUse(token)
        await useRecorder.settle { $0.count >= 2 }
        XCTAssertEqual(useRecorder.states(of: id), [.loaded, .downloaded], "ровно по одному stateChanged")
    }
}
