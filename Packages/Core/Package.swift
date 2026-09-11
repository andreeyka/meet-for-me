// swift-tools-version: 5.9
//
//  MeetCore — модули, не зависящие от macOS-фреймворков.
//  Собираются и тестируются где угодно, в том числе в облачной сессии DEV-2 и на Linux в CI.
//
//  Владелец файла — архитектор. Новый таргет, новая зависимость между таргетами или новая
//  внешняя зависимость — это изменение границ модулей: interface-request, а не коммит (П2, П6).
//
//  Правило графа: всё зависит от DomainCore и ни один модуль не зависит от другого напрямую.
//  Конкретные реализации связываются в composition root приложения (модуль app-ui).

import PackageDescription

let package = Package(
    name: "MeetCore",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "DomainCore", targets: ["DomainCore"]),
        .library(name: "DomainTestKit", targets: ["DomainTestKit"]),
        .library(name: "Storage", targets: ["Storage"]),
        .library(name: "CalendarHub", targets: ["CalendarHub"]),
        .library(name: "EngineKit", targets: ["EngineKit"]),
        .library(name: "GigaAM", targets: ["GigaAM"]),
        .library(name: "ModelManager", targets: ["ModelManager"]),
        .library(name: "Attribution", targets: ["Attribution"]),
    ],
    targets: [
        // домен: DTO, порты, машина состояний, Scheduler, JobQueue — только Foundation
        .target(name: "DomainCore"),
        // фейки портов домена: живут отдельно, чтобы не тянуть системные фреймворки
        .target(name: "DomainTestKit", dependencies: ["DomainCore"]),

        .target(name: "Storage", dependencies: ["DomainCore"]),
        .target(name: "CalendarHub", dependencies: ["DomainCore"]),
        .target(name: "EngineKit", dependencies: ["DomainCore"]),
        .target(name: "GigaAM", dependencies: ["EngineKit"]),
        .target(name: "ModelManager", dependencies: ["DomainCore"]),
        .target(name: "Attribution", dependencies: ["DomainCore", "EngineKit"]),

        // resources: эталонные manifest.json и transcript.v1.json — экземпляры спецификации
        // форматов C-002 и C-003, а не оснастка теста (решение по IR-003, MEE-17).
        // Каталог Fixtures/ принадлежит архитектору; тест читает его через Bundle.module в Data.
        .testTarget(
            name: "DomainCoreTests",
            dependencies: ["DomainCore", "DomainTestKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "StorageTests", dependencies: ["Storage", "DomainTestKit"]),
        .testTarget(name: "CalendarHubTests", dependencies: ["CalendarHub", "DomainTestKit"]),
        .testTarget(name: "EngineKitTests", dependencies: ["EngineKit", "DomainTestKit"]),
        .testTarget(name: "GigaAMTests", dependencies: ["GigaAM", "DomainTestKit"]),
        .testTarget(name: "ModelManagerTests", dependencies: ["ModelManager", "DomainTestKit"]),
        .testTarget(name: "AttributionTests", dependencies: ["Attribution", "DomainTestKit"]),
    ]
)
