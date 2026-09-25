// swift-tools-version: 5.9
//
//  Спайк R12 (MEE-426, docs/architecture.md): измеряет реальную скорость (RTF), пик памяти и
//  время загрузки GigaAM v3 `e2e_ctc` на Apple Silicon через sherpa-onnx.
//  Код вне модулей продукта и в продукт не переезжает без отдельной задачи с контрактом
//  (spikes/README.md, docs/module-map.md — «Спайки не принадлежат модулям»).
//
//  Отдельный пакет, а не таргет в Packages/Mac: официальный SwiftPM-пакет k2-fsa/sherpa-onnx
//  тянет ~168 МиБ бинарных XCFramework-архивов (sherpa-onnx 1.13.8 + onnxruntime-libs 1.28.2,
//  варианты под iOS/visionOS включены, спайку не нужные) — цена не должна ложиться на каждую
//  сборку Packages/Mac и на каждый прогон CI job «Core + Mac», как легла бы, будь это таргет
//  общего пакета (возврат РП, MEE-426, приёмка #158). CI этот пакет не собирает (spikes/README.md
//  — «CI спайки не собирает»), тем же приёмом, что уже принят для `spikes/capture-cli`.
//
//  Сборка, запуск, источник модели — spikes/GigaAMSpike/README.md.

import PackageDescription

let package = Package(
    name: "GigaAMSpike",
    platforms: [.macOS("14.4")],
    dependencies: [
        // Версия зафиксирована точно, не диапазоном: спайк — не место для сюрприза от
        // подхваченного новее бинарника без предупреждения.
        .package(url: "https://github.com/k2-fsa/sherpa-onnx", exact: "1.13.8"),
    ],
    targets: [
        // `scripts/` и `README.md` лежат в корне пакета (не под `Sources/`), поэтому
        // SwiftPM не сканирует их как файлы таргета — предупреждение «unhandled files»
        // (была причина исключений в Packages/Mac/Package.swift) здесь не возникает.
        .executableTarget(
            name: "GigaAMSpikeHarness",
            dependencies: [.product(name: "sherpa-onnx", package: "sherpa-onnx")]
        )
    ]
)
