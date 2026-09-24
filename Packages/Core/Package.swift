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

// swiftlint:disable trailing_comma

// MEE-321, условие Г — решено прогоном CI, не рассуждением: GRDB 6.29.3
// (закреплённая версия, последняя линии v6, swift-tools-version 5.7) на
// прогоне Core (Linux) (swift:5.10-jammy, libsqlite3-dev установлен) собрал
// исходники, но упал на ЛИНКЕ — `undefined reference to 'sqlite3_snapshot_open'`
// и три соседних символа (DatabaseSnapshotPool.swift, WALSnapshot.swift).
// Причина не в нашей зависимости: guard самого GRDB
// (`GRDB/Core/WALSnapshot.swift`, строка 1) —
// `#if SQLITE_ENABLE_SNAPSHOT || (!GRDBCUSTOMSQLITE && !GRDBCIPHER &&
// (compiler(>=5.7.1) || …))` — компилирует WAL-snapshot API БЕЗУСЛОВНО на
// любом компиляторе ≥5.7.1, полагая, что системный SQLite снимает snapshot
// (верно для Apple SQLite на macOS/iOS, неверно для `libsqlite3-dev` Ubuntu:
// пакет собран без `SQLITE_ENABLE_SNAPSHOT`). Загрузка без даунстрим-обхода
// подтверждена цитатой мейнтейнера в discussion groue/GRDB.swift#1821: фикс
// требует правки пяти файлов САМОГО GRDB (`&& !os(Linux)` в каждом guard'е) —
// то есть форка, а не параметра нашего Package.swift; на дату решения фикс не
// вошёл ни в одно издание GRDB. Условие Г — ЛОЖНО.
//
// Решение: Storage/StorageTests и зависимость GRDB объявлены только когда
// манифест разбирается НЕ на Linux (`#if !os(Linux)` — стандартная условная
// компиляция Swift, действует и на Package.swift, поскольку его разбирает тот
// же тулчейн, что собирает пакет). На Core (Linux) таргетов Storage/
// StorageTests в графе нет вовсе — SwiftPM не пытается ни резолвить GRDB, ни
// собирать/линковать её; на Core + Mac (macos-14) — оба таргета в графе, GRDB
// резолвится и линкуется штатно (Apple SQLite snapshot умеет). Отвергнутые
// способы и их цена — в отчёте MEE-321 (комментарий в задаче).
#if !os(Linux)
let includeStorage = true
#else
let includeStorage = false
#endif

var products: [Product] = [
    .library(name: "DomainCore", targets: ["DomainCore"]),
    .library(name: "DomainTestKit", targets: ["DomainTestKit"]),
    .library(name: "CalendarHub", targets: ["CalendarHub"]),
    .library(name: "EngineKit", targets: ["EngineKit"]),
    .library(name: "GigaAM", targets: ["GigaAM"]),
    .library(name: "ModelManager", targets: ["ModelManager"]),
    .library(name: "Attribution", targets: ["Attribution"]),
]

var dependencies: [Package.Dependency] = []

var targets: [Target] = [
    // домен: DTO, порты, машина состояний, Scheduler, JobQueue — только Foundation
    .target(name: "DomainCore", resources: [.copy("signal-weights.json")]),
    // фейки портов домена: живут отдельно, чтобы не тянуть системные фреймворки
    .target(name: "DomainTestKit", dependencies: ["DomainCore"]),

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
    .testTarget(name: "CalendarHubTests", dependencies: ["CalendarHub", "DomainTestKit"]),
    .testTarget(name: "EngineKitTests", dependencies: ["EngineKit", "DomainTestKit"]),
    .testTarget(name: "GigaAMTests", dependencies: ["GigaAM", "DomainTestKit"]),
    .testTarget(name: "ModelManagerTests", dependencies: ["ModelManager", "DomainTestKit"]),
    .testTarget(name: "AttributionTests", dependencies: ["Attribution", "DomainTestKit"]),
]

if includeStorage {
    products.append(.library(name: "Storage", targets: ["Storage"]))
    // Версия закреплена точно (exact), а не диапазоном: последнее издание
    // линии v6 — линия v7 требует swift-tools-version 6.1 и Swift 6.1+,
    // несовместима с тулчейном 5.10 (не собралась бы и на Core + Mac ровно
    // тем же способом, каким v6 не линкуется на Core (Linux)).
    dependencies.append(.package(url: "https://github.com/groue/GRDB.swift", exact: "6.29.3"))
    // ВРЕМЕННО, проверочная ветка MEE-191 (возврат РП 24.09, п.2): изолированный таргет
    // имитирует стороннюю зависимость наподобие GRDB — объявляет свой тип с именем, которое
    // совпадает с разрешённым именем ИЗ ДРУГОГО модуля (`Foundation.Date`), но им не является.
    // Изолирован в собственном таргете нарочно: у `Date` внутри `DomainCore`/`DomainTestKit`
    // десятки словоупотреблений, и то же имя в их собственном пространстве имён сломало бы
    // саму сборку затенением, а не проверило бы разбор символьного графа. Снимается вместе с
    // прочими нарушителями этой ветки, в main не попадает.
    targets.append(.target(name: "VerifyMEE191", dependencies: []))
    targets.append(
        .target(
            name: "Storage",
            dependencies: [
                "DomainCore",
                "VerifyMEE191",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        )
    )
    targets.append(
        .testTarget(
            name: "StorageTests",
            dependencies: [
                "Storage",
                "DomainTestKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        )
    )
}

let package = Package(
    name: "MeetCore",
    platforms: [.macOS("14.4")],
    products: products,
    dependencies: dependencies,
    targets: targets
)
// swiftlint:enable trailing_comma
