// swift-tools-version: 5.9
//
//  Стенд Z6 (MEE-504, решение IR-152 в MEE-486): хост-клиент, который зовёт настоящий
//  `TranscriptionEngine.xpc` через `EngineXPCClient` — тот же путь, что у приложения, — и меряет
//  RTF, пик памяти процесса сервиса, отмену и отказ «нет модели».
//
//  Отдельный пакет в `spikes/`, а не таргет в `Packages/Mac`: `Package.swift` там — файл архитектора,
//  а стенд — носитель ручного прогона на Mac РП, CI его не собирает (spikes/README.md). Код отсюда
//  в продукт не переезжает. Сборка и запуск — README.md рядом.

import PackageDescription

let package = Package(
    name: "GigaAMXPCHarness",
    platforms: [.macOS("14.4")],
    dependencies: [
        .package(path: "../../Packages/Core"),
        .package(path: "../../Packages/Mac")
    ],
    targets: [
        .executableTarget(
            name: "GigaAMXPCHarness",
            dependencies: [
                .product(name: "DomainCore", package: "Core"),
                .product(name: "DomainTestKit", package: "Core"),
                .product(name: "ModelManager", package: "Core"),
                .product(name: "EngineXPCClient", package: "Mac")
            ]
        )
    ]
)
