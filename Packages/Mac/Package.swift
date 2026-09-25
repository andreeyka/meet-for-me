// swift-tools-version: 5.9
//
//  MeetMac — модули, которым нужны macOS-фреймворки (CoreAudio, AVFoundation, EventKit, XPC).
//  Собираются только на macOS: локально у DEV-1 и DEV-3 и на раннере macos-14 в CI.
//
//  Владелец файла — архитектор (см. комментарий в Packages/Core/Package.swift).
//
//  Каждый модуль здесь — адаптер: реализует порт из DomainCore и не знает ни о других
//  адаптерах, ни о UI, ни о хранилище.

import PackageDescription

// swiftlint:disable trailing_comma
let package = Package(
    name: "MeetMac",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "Capture", targets: ["Capture"]),
        .library(name: "Permissions", targets: ["Permissions"]),
        .library(name: "Detector", targets: ["Detector"]),
        .library(name: "CalendarEventKit", targets: ["CalendarEventKit"]),
        .library(name: "EngineXPCClient", targets: ["EngineXPCClient"]),
        .library(name: "SecretStoreKeychain", targets: ["SecretStoreKeychain"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        // Спайк R12 (MEE-426): официальный SwiftPM-пакет k2-fsa/sherpa-onnx — C API рантайма
        // ONNX Runtime для GigaAM v3 e2e_ctc (решение Q10 architecture.md: путь через
        // CPU-этап на sherpa-onnx). Версия зафиксирована точно, не диапазоном: спайк — не
        // место для сюрприза от подхваченного новее бинарника без предупреждения; запись —
        // GigaAMSpikeHarness, docs/module-map.md («Спайки не принадлежат модулям»).
        .package(url: "https://github.com/k2-fsa/sherpa-onnx", exact: "1.13.8"),
    ],
    targets: [
        .target(name: "Capture", dependencies: [.product(name: "DomainCore", package: "Core")]),
        .target(name: "Permissions", dependencies: [.product(name: "DomainCore", package: "Core")]),
        .target(name: "Detector", dependencies: [.product(name: "DomainCore", package: "Core")],
                resources: [.copy("providers.json"), .copy("clients.json")]),
        .target(name: "CalendarEventKit", dependencies: [.product(name: "DomainCore", package: "Core")]),
        // Харнесс модуля capture (MEE-316): носитель ручных М1/М2 и писатель К27(б) плана
        // MEE-315. Исполняемый таргет в этом же пакете, а не отдельный пакет: доступ
        // `package` не пересекает границу SPM-пакета, а писателю нужна точка входа
        // записи внутри Capture. Каталог принадлежит модулю capture (docs/module-map.md).
        .executableTarget(
            name: "CaptureManualHarness",
            dependencies: ["Capture", .product(name: "DomainCore", package: "Core")]
        ),
        // Харнесс модуля calendar-eventkit (IR-119, MEE-351): носитель ручных М1/М2 плана
        // MEE-343 §5 — измеряет факты о самом EventKit (граница «весь день», развёртка
        // повторений, код ошибки при отозванном праве) вызовом `EKEventStore` НАПРЯМУЮ, в
        // обход calendar-eventkit. Не зависит от таргета `CalendarEventKit`: в отличие от
        // `CaptureManualHarness` (нужна точка входа записи внутри Capture), этому харнессу
        // не нужен ни один тип модуля — только сам EventKit. В этом пакете, а не отдельном,
        // потому что EventKit собирается только на macOS, как и весь `Packages/Mac`. Каталог
        // принадлежит модулю calendar-eventkit (docs/module-map.md).
        .executableTarget(
            name: "CalendarEventKitManualHarness",
            dependencies: [.product(name: "DomainCore", package: "Core")]
        ),
        // Спайк R12 (MEE-426, docs/architecture.md): измеряет реальную скорость (RTF), пик
        // памяти и время загрузки GigaAM v3 `e2e_ctc` на Apple Silicon через sherpa-onnx.
        // Код спайка, не модуль (docs/module-map.md — «Спайки не принадлежат модулям»):
        // в этом пакете, а не в spikes/, только потому что spikes/ не собирает CI, а
        // готовность MEE-426 требует зелёной сборки на macos-14. Ни модель, ни тестовый WAV
        // в репозиторий не входят — записка MEE-426 называет источник модели, скрипт
        // `scripts/download-model.sh` только печатает URL и размер без флага `--yes`.
        .executableTarget(
            name: "GigaAMSpikeHarness",
            dependencies: [.product(name: "sherpa-onnx", package: "sherpa-onnx")],
            exclude: ["scripts"]
        ),
        .target(
            name: "EngineXPCClient",
            dependencies: [
                .product(name: "DomainCore", package: "Core"),
                .product(name: "EngineKit", package: "Core"),
            ]
        ),
        // IR-122 (MEE-358): реализация протокола `SecretStore`, объявленного `CalendarHub`
        // (не `DomainCore`) — хранилище секретов коннекторов поверх Keychain (`Security`).
        // Каркас без кода — реализация задачей DEV-1, docs/module-map.md.
        .target(
            name: "SecretStoreKeychain",
            dependencies: [.product(name: "CalendarHub", package: "Core")]
        ),

        .testTarget(
            name: "CaptureTests",
            dependencies: ["Capture", .product(name: "DomainTestKit", package: "Core")]
        ),
        .testTarget(
            name: "PermissionsTests",
            dependencies: ["Permissions", .product(name: "DomainTestKit", package: "Core")]
        ),
        .testTarget(
            name: "DetectorTests",
            dependencies: ["Detector", .product(name: "DomainTestKit", package: "Core")]
        ),
        .testTarget(
            name: "CalendarEventKitTests",
            dependencies: ["CalendarEventKit", .product(name: "DomainTestKit", package: "Core")]
        ),
        .testTarget(
            name: "EngineXPCClientTests",
            dependencies: ["EngineXPCClient", .product(name: "DomainTestKit", package: "Core")]
        ),
        .testTarget(
            name: "SecretStoreKeychainTests",
            dependencies: ["SecretStoreKeychain", .product(name: "CalendarHub", package: "Core")]
        ),
    ]
)
// swiftlint:enable trailing_comma
