# Services/TranscriptionEngineXPC — модуль `engine-xpc`, владелец DEV-2

Точка входа XPC-сервиса `TranscriptionEngine.xpc`: тонкая обвязка `NSXPCConnection` вокруг
протоколов из таргета `EngineKit`. Вся логика инференса — в `Packages/Core/Sources/EngineKit`
и `Packages/Core/Sources/GigaAM`, чтобы она собиралась и тестировалась вне macOS.

Сервис ничего не скачивает: пути к моделям приходят снаружи от `model-manager` (C-014).
