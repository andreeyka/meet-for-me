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

let package = Package(
    name: "MeetMac",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "Capture", targets: ["Capture"]),
        .library(name: "Permissions", targets: ["Permissions"]),
        .library(name: "Detector", targets: ["Detector"]),
        .library(name: "CalendarEventKit", targets: ["CalendarEventKit"]),
        .library(name: "EngineXPCClient", targets: ["EngineXPCClient"]),
    ],
    dependencies: [
        .package(path: "../Core"),
    ],
    targets: [
        .target(name: "Capture", dependencies: [.product(name: "DomainCore", package: "Core")]),
        .target(name: "Permissions", dependencies: [.product(name: "DomainCore", package: "Core")]),
        .target(name: "Detector", dependencies: [.product(name: "DomainCore", package: "Core")]),
        .target(name: "CalendarEventKit", dependencies: [.product(name: "DomainCore", package: "Core")]),
        .target(
            name: "EngineXPCClient",
            dependencies: [
                .product(name: "DomainCore", package: "Core"),
                .product(name: "EngineKit", package: "Core"),
            ]
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
    ]
)
