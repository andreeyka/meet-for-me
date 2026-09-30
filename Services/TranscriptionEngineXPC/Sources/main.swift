//  TranscriptionEngineXPC — точка входа XPC-сервиса (MEE-438).
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок
//
//  Каталог принадлежит владельцу модуля: файлы здесь изменяет только он (П1), кроме
//  `project.yml` в корне репозитория — тот отдельно принадлежит архитектору (module-map.md,
//  §2) и заводит сам таргет (MEE-430); правка `project.yml`, добавившая этому таргету
//  зависимости `Mac/EngineXPCService` и `Mac/EngineXPCClient`, — раскрытый в PR
//  interface-request, не тихая правка (сама эта задача её не разрешала явно, только
//  Package.swift — механическое следствие того же решения, см. PR).
//
//  Тонкая точка входа: `NSXPCListener.service()` — стандартный вход встроенного XPC-сервиса
//  (`Contents/XPCServices/…`, C-012 v10). Сама диспетчерская логика — в библиотечном таргете
//  `EngineXPCService` (Packages/Mac, `EngineXPCRequestHandler`), ради SwiftPM-тестируемости
//  (правка Package.swift разрешена РП заранее для MEE-438, раскрыта в PR). `NSObject`/`@objc`-
//  обвязка вокруг него (`ServiceConnectionDelegate.swift`, этот же каталог) заведена ЗДЕСЬ, а
//  не в `EngineXPCService`, — см. заголовок `EngineXPCRequestHandler.swift` за доводом
//  (символьный граф CI не смотрит этот каталог вовсе, а `EngineXPCService` без
//  `allowed-types/EngineXPCService.json`, не разрешённого этой задачей, не может публично
//  нести `NSObject`/`NSXPCConnection`).
//
//  Движки (MEE-504, Z6 решения IR-152): транскрипция — `GigaAMEngine` (модуль gigaam) с
//  распознавателем sherpa-onnx (`SherpaGigaAMRecognizerFactory`, таргет `GigaAMSherpa`) и чтением
//  дорожек `TrackAudioSource` (этот каталог, поверх `AudioTrackReader`). Остальные три — честные
//  заглушки `Unavailable*`: диаризации, эмбеддингов и постобработки в Срезе 1 нет.
//
//  Журнал движка (MEE-513, IR-157): причина `modelMissing` при проверке каталога модели — файл,
//  ожидаемая и найденная длина, нет или не читается `.manifest.json` — идёт в unified log уровнем
//  `error`, подсистема `com.andreeyka.meetforme.TranscriptionEngine`, категория `model`. `GigaAM`
//  (Packages/Core) `os` не импортирует: строку он отдаёт замыканием `log`.

import EngineXPCService
import Foundation
import GigaAM
import GigaAMSherpa
import os

let modelLog = Logger(subsystem: "com.andreeyka.meetforme.TranscriptionEngine", category: "model")
let engines = EngineBundle(
    transcription: GigaAMEngine(
        audioSource: TrackAudioSource(), recognizerFactory: SherpaGigaAMRecognizerFactory(),
        log: { message in modelLog.error("\(message, privacy: .public)") }
    ),
    diarization: UnavailableDiarizationEngine(),
    embedding: UnavailableEmbeddingEngine(),
    postProcessor: UnavailablePostProcessor()
)
let delegate = ServiceConnectionDelegate(engines: engines, serviceVersion: "meet-for-me-engine-xpc")
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
