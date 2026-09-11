// swift-tools-version: 5.9
//
//  Спайк MEE-8: захват звука через Core Audio process tap + микрофон в aggregate device.
//  Код вне модулей продукта и в продукт не переезжает (spikes/README.md).
//  Сборка, подпись и запуск — spikes/capture-cli/README.md.

import PackageDescription

let package = Package(
    name: "capture-cli",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "capture-cli", path: "Sources/capture-cli")
    ]
)
