# Services/TranscriptionEngineXPC — модуль `engine-xpc`, владелец DEV-2

Точка входа XPC-сервиса `TranscriptionEngine.xpc`: тонкая обвязка `NSXPCConnection` вокруг
протоколов из таргета `EngineKit`. Вся логика инференса — в `Packages/Core/Sources/EngineKit`
и `Packages/Core/Sources/GigaAM`, чтобы она собиралась и тестировалась вне macOS.

Сервис ничего не скачивает: пути к моделям приходят снаружи от `model-manager` (C-014).

Таргет Xcode-проекта — `TranscriptionEngine` (имя таргета = имя продукта `.xpc`, не имя
каталога), заведён архитектором каркасом в `project.yml` (MEE-430; сам этот файл — не зона
DEV-2, только исходники в `Sources/` ниже). `Sources/main.swift` — точка входа,
`NSXPCListener.service()`; транскрипция — `GigaAMEngine` с распознавателем sherpa-onnx
(MEE-504), остальные движки — заглушки `Unavailable*`. `Sources/TrackAudioSource.swift` —
чтение дорожек для GigaAM и лог швов (категория `seams`, как смотреть — в заголовке файла).
