// swift-tools-version: 5.9
//
//  MeetMac — модули, которым нужны macOS-фреймворки (CoreAudio, AVFoundation, EventKit, XPC).
//  Собираются только на macOS: локально у DEV-1 и на раннере macos-14 в CI.
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
        .library(name: "EngineXPCService", targets: ["EngineXPCService"]),
        .library(name: "SecretStoreKeychain", targets: ["SecretStoreKeychain"]),
        .library(name: "GigaAMSherpa", targets: ["GigaAMSherpa"]),
    ],
    dependencies: [
        .package(path: "../Core"),
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
        .target(
            name: "EngineXPCClient",
            dependencies: [
                .product(name: "DomainCore", package: "Core"),
                .product(name: "EngineKit", package: "Core"),
            ]
        ),
        // MEE-438: сторона сервиса Services/TranscriptionEngineXPC — диспетчерская логика
        // (`EngineXPCRequestHandler`) вынесена сюда библиотечным таргетом ради SwiftPM-
        // тестируемости (правка этого файла разрешена РП заранее, раскрыта в PR). Ни
        // `NSObject`, ни `NSXPCConnection`, ни `@objc` здесь нет намеренно — заголовок
        // `EngineXPCRequestHandler.swift` называет довод (символьный граф CI держит для
        // таргетов без `allowed-types/<Target>.json` барьер по модулю объявления, а
        // `<C/ObjC>` в него не входит; заводить такой файл эта задача не разрешала). Оттого
        // и не зависит от `EngineXPCClient` — обвязка вокруг `EngineXPCServiceProtocol`/
        // `EngineXPCClientProtocol` (двоичные сигнатуры провода, MEE-431) заведена отдельно
        // в каждом потребителе (`Services/TranscriptionEngineXPC/Sources/
        // ServiceConnectionDelegate.swift` — прод; `EngineXPCServiceTests/TestSupport.swift` —
        // тесты), не в этом таргете.
        .target(
            name: "EngineXPCService",
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
        // IR-152 (MEE-486), MEE-503: адаптер модуля gigaam — `GigaAMRecognizer` поверх sherpa-onnx.
        // Единственный таргет репозитория, которому разрешён `import SherpaOnnxC` (docs/module-map.md).
        // `c++` — рантайм C++ обоих статических архивов (так же линковала обёртка пакета sherpa-onnx).
        .target(
            name: "GigaAMSherpa",
            dependencies: [
                .product(name: "GigaAM", package: "Core"),
                "SherpaOnnxMacOSStatic",
                "OnnxRuntimeMacOSStatic",
            ],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        // IR-156 (MEE-507, MEE-512): рантайм распознавания модуля gigaam — два собственных
        // статических XCFramework вместо пакета `k2-fsa/sherpa-onnx`. Пакет нёс под macOS
        // статический и разделяемый `SherpaOnnxC.framework` под одним именем, и SwiftPM 5.10
        // копировал в `.build/debug` случайный из двух (гонка `Set`, обход
        // `SWIFT_DETERMINISTIC_HASHING` в CI). Здесь фреймворк с этим именем один — гонки нет.
        // URL и `checksum` — дословно из манифестов sherpa-onnx 1.13.8 (`SherpaOnnxMacOS`) и
        // onnxruntime-libs 1.28.2 (`OnnxruntimeMacOS`); смена версии — решение архитектора.
        // Swift-обёртка пакета (`SherpaOnnx.swift`) не нужна: адаптер строит конфигурацию C API.
        .binaryTarget(
            name: "SherpaOnnxMacOSStatic",
            // swiftlint:disable:next line_length
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-macos-static.xcframework.zip",
            checksum: "93f7a064abe99e0d6185a88c5b36ce18c4bff35cd0d5e4e81f81151de8e3e7e5"
        ),
        .binaryTarget(
            name: "OnnxRuntimeMacOSStatic",
            // swiftlint:disable:next line_length
            url: "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/onnxruntime-macos-static-xcframework-1.28.2.xcframework.zip",
            checksum: "cb0b0bec912c77229517c463e28a3fac9674c521f9599919efff1ef2b42f3da0"
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
            dependencies: [
                "EngineXPCClient",
                .product(name: "DomainTestKit", package: "Core"),
                .product(name: "EngineKit", package: "Core"),
            ]
        ),
        .testTarget(
            name: "SecretStoreKeychainTests",
            dependencies: ["SecretStoreKeychain", .product(name: "CalendarHub", package: "Core")]
        ),
        .testTarget(
            name: "EngineXPCServiceTests",
            dependencies: [
                "EngineXPCService",
                "EngineXPCClient",
                .product(name: "DomainTestKit", package: "Core"),
                .product(name: "EngineKit", package: "Core"),
            ]
        ),
        // Тест с моделью включается `GIGAAM_MODEL_DIR` (иначе XCTSkip) — модель лежит только на Mac РП.
        .testTarget(
            name: "GigaAMSherpaTests",
            dependencies: ["GigaAMSherpa", .product(name: "GigaAM", package: "Core")]
        ),
    ]
)
// swiftlint:enable trailing_comma
