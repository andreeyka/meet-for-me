//  К24, К25 перечня MEE-429 (группа Е): пороги чипа, памяти и места — до первого обращения
//  к транспорту. Чип, память и место — внутренний шов `MachineEnvironment` (решение РП по
//  К24/К25), не системный вызов: на `Core (Linux)` подменить иначе нечем.

import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

extension DownloadTests {

    func test_k24_chipAndRamThresholdsRejectBeforeTransportSendViaInternalSeam() async throws {
        // Фикстура «модель с minChip == .m4» — как действующий каталог.
        let harness = ModelHarness(models: [])
        harness.machine.set(chip: .m2)
        let manager = try harness.makeManager(builtIn: CatalogFixtures.minChipM4JSON)
        let asr = try XCTUnwrap(CatalogFixtures.minChipM4Catalog.models.first { $0.minChip == .m4 })
        await expectError(.unsupportedChip(required: .m4)) {
            try await manager.download(id: asr.id, version: asr.version)
        }
        XCTAssertTrue(harness.transport.requests.isEmpty, "до начала загрузки: обращений к транспорту 0")

        // Память: модель требует 8 ГБ, у машины 4.
        let model = TestModel.make(id: "ram-asr", minChip: .m1, minRAMGB: 8,
                                   files: [("x.bin", TestModel.bytes(8, seed: 13))])
        let ramHarness = ModelHarness(models: [model])
        ramHarness.machine.set(memoryGB: 4)
        let ramManager = try ramHarness.makeManager()
        await expectError(.insufficientRAM(requiredGB: 8)) {
            try await ramManager.download(id: "ram-asr", version: "1.0.0")
        }
        XCTAssertTrue(ramHarness.transport.requests.isEmpty)
        ramHarness.machine.set(memoryGB: 8)
        try await ramManager.download(id: "ram-asr", version: "1.0.0")
        XCTAssertFalse(ramHarness.transport.requests.isEmpty, "вектор непустоты: при достатке памяти загрузка идёт")
    }

    func test_k25_insufficientDiskSpaceRejectsBeforeTransportSendViaInternalSeam() async throws {
        let model = TestModel.make(id: "disk-full", files: [("d.bin", TestModel.bytes(64, seed: 14))])
        let harness = ModelHarness(models: [model])
        harness.machine.set(diskBytes: 10)
        let manager = try harness.makeManager()
        await expectError(.insufficientDiskSpace(requiredBytes: 64, availableBytes: 10)) {
            try await manager.download(id: "disk-full", version: "1.0.0")
        }
        XCTAssertTrue(harness.transport.requests.isEmpty, "до начала загрузки, а не посреди неё")
        let state = await manager.state(id: "disk-full", version: "1.0.0")
        XCTAssertEqual(state, .available)
    }
}
