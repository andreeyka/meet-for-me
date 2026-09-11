# Карта модулей

Версия 1 (черновик, ожидает утверждения). Источник: `docs/architecture.md` v0.6.
Точка утверждения и обсуждения — issue с меткой `design` в Linear (проект «Срез 1: запись → транскрипт»).

Карта отвечает на один вопрос: **какой файл кому принадлежит**. Разработчик изменяет только файлы каталогов своего
модуля; всё, что пересекает границу, описано контрактом архитектора (метка `contract` в Linear).

## 1. Раскладка репозитория

Конструкция: логика — в таргетах SwiftPM (границы модулей проверяет компилятор: чужой модуль просто не импортируется),
бандлы приложения и XPC-сервиса — в проекте Xcode, генерируемом XcodeGen из текстового `project.yml`
(бинарный `.xcodeproj` в репозиторий не коммитится — он неразрешимо конфликтует между тремя сессиями).

```
Package.swift              ← архитектор: список таргетов и зависимостей между модулями
project.yml                ← архитектор: App и XPC-таргеты, entitlements, подпись (XcodeGen)
.swiftlint.yml, Makefile   ← архитектор
.github/workflows/         ← архитектор: сборка и тесты на macos-14
docs/                      ← архитектор: архитектурный документ, карта модулей, журнал решений
Sources/<Модуль>/          ← код модуля (см. таблицу)
Tests/<Модуль>Tests/       ← тесты модуля, принадлежат владельцу модуля
App/                       ← app-ui: App-таргет, меню-бар, окна, composition root
Services/TranscriptionEngineXPC/  ← engine-xpc: точка входа XPC-сервиса
Plugins/graph/             ← plugin-graph: внешний процесс-коннектор Outlook
spikes/<имя>/              ← спайки: код вне модулей, в продукт не переезжает без отдельной задачи
```

Файлы сборки (`Package.swift`, `project.yml`, `.github/`, `.swiftlint.yml`, `Makefile`) принадлежат **архитектору**:
они по природе перечисляют все модули сразу, и их правка разработчиком — это изменение границ, то есть
`interface-request`, а не коммит.

## 2. Владельцы и среда

| Владелец | Где работает | Модули |
| -- | -- | -- |
| DEV-1 | сессия на Mac с Xcode | `capture`, `permissions`, `detector`, `calendar-eventkit` |
| DEV-2 | облачная сессия (Linux) + проверка на macos-14 в CI | `domain-core`, `storage`, `calendar-hub`, `engine-xpc`, `gigaam`, `model-manager`, `attribution`, `plugin-graph` |
| DEV-3 | сессия на Mac с Xcode | `app-ui` |
| Архитектор | сессия РП | файлы сборки, `docs/`, контракты |

DEV-2 работает в облаке, поэтому все его модули обязаны собираться без macOS-фреймворков: `domain-core` — только
Foundation, `storage` — Foundation + GRDB, `engine-xpc`/`gigaam` — код инференса отделён от `NSXPCConnection`
(сама XPC-обвязка проверяется на CI и на Mac). Это не пожелание, а условие, при котором DEV-2 вообще может
прогнать свои тесты.

Объективный барьер приёмки для всех троих — зелёный прогон на macos-14 в GitHub Actions. Локальный прогон
у DEV-1 и DEV-3 обязателен до PR, но приёмку закрывает CI.

## 3. Модули

### МОДУЛЬ: domain-core
- Слой: домен
- Процесс: App
- Каталоги: `Sources/DomainCore/`, `Sources/DomainTestKit/`, `Tests/DomainCoreTests/`
- Владелец: DEV-2
- Реализует контракты: DTO (`MeetingEvent`, `RecordingManifest`, `Transcript`, `JoinInfo`, `MeetingSignal`), определения портов
  (`AudioCapturePort`, `CalendarPort`, `PermissionsPort`, `ProcessMonitorPort`, `PowerPort`), машина состояний
  `SessionCoordinator`, `Scheduler`, интерфейс `JobQueue`, фейки всех портов в `DomainTestKit`
- Потребляет контракты: —
- Запрещено: импорт AppKit, SwiftUI, AVFoundation, CoreAudio, EventKit, GRDB, XPC. Только Foundation.
  Никаких файловых путей и синглтонов: всё снаружи приходит через порты.

`DomainTestKit` — отдельный таргет с фейками портов, чтобы фейк `AudioCapturePort` не тянул CoreAudio и
компилировался в облачной сессии и на CI.

### МОДУЛЬ: capture
- Слой: адаптер системного API
- Процесс: App
- Каталоги: `Sources/Capture/`, `Tests/CaptureTests/`
- Владелец: DEV-1
- Реализует контракты: `AudioCapturePort` (process tap + микрофон в aggregate device, чанкованный CAF, `RecordingManifest` на выходе)
- Потребляет контракты: `PowerPort`, DTO домена
- Запрещено: импорт SwiftUI/AppKit, прямая запись в БД, знание о календаре и о движке транскрибации;
  решение «писать или не писать» принимает домен, модуль только исполняет

### МОДУЛЬ: permissions
- Слой: адаптер системного API
- Процесс: App
- Каталоги: `Sources/Permissions/`, `Tests/PermissionsTests/`
- Владелец: DEV-1
- Реализует контракты: `PermissionsPort` (микрофон, System Audio Recording, календарь, уведомления, login item), `PowerPort` (сон, App Nap, тепловое состояние)
- Потребляет контракты: —
- Запрещено: показ собственного UI (мастер прав рисует `app-ui`, модуль отдаёт только состояние и команду «открыть раздел настроек»)

### МОДУЛЬ: detector
- Слой: адаптер системного API + таблицы правил
- Процесс: App
- Каталоги: `Sources/Detector/`, `Tests/DetectorTests/`
- Владелец: DEV-1
- Реализует контракты: `ProcessMonitorPort` (процессы, аудиоактивность, PID для тапа), `PlatformResolver` (разбор ссылки → `JoinInfo`)
- Потребляет контракты: DTO домена; таблицы правил — данные в ресурсах модуля, не код
- Запрещено: запуск и остановка записи (решение принимает `SessionCoordinator`), доступ к Storage

### МОДУЛЬ: calendar-eventkit
- Слой: плагин (адаптер системного API)
- Процесс: App (in-process, подписан тем же Team ID)
- Каталоги: `Sources/CalendarEventKit/`, `Tests/CalendarEventKitTests/`
- Владелец: DEV-1
- Реализует контракты: протокол плагина календаря (Swift-зеркало), выдаёт `MeetingEvent`
- Потребляет контракты: `PermissionsPort`, сервисы хоста (secrets, log, notify)
- Запрещено: дедупликация и нормализация событий (это хост), запись в БД, собственное расписание опроса

### МОДУЛЬ: calendar-hub
- Слой: домен
- Процесс: App
- Каталоги: `Sources/CalendarHub/`, `Tests/CalendarHubTests/`
- Владелец: DEV-2
- Реализует контракты: `CalendarPort`, хост плагинов (in-process и stdio JSON-RPC), нормализация и дедуп
  (ключ: join-URL → ICS UID → организатор+время), расписание опроса
- Потребляет контракты: протокол плагина календаря, репозитории `storage`
- Запрещено: импорт EventKit и любых Apple-фреймворков сверх Foundation; знание о конкретных коннекторах

### МОДУЛЬ: storage
- Слой: хранилище
- Процесс: App
- Каталоги: `Sources/Storage/`, `Tests/StorageTests/`
- Владелец: DEV-2
- Реализует контракты: схема SQLite и миграции, репозитории по DTO, FTS5, раскладка файлов записей
- Потребляет контракты: DTO домена
- Запрещено: бизнес-решения (что записывать, когда транскрибировать); отдавать наружу типы GRDB —
  за границу модуля проходят только DTO

### МОДУЛЬ: engine-xpc
- Слой: движок
- Процесс: XPC-сервис
- Каталоги: `Sources/EngineKit/`, `Services/TranscriptionEngineXPC/`, `Tests/EngineKitTests/`
- Владелец: DEV-2
- Реализует контракты: протоколы `TranscriptionEngine`, `DiarizationEngine`, `EmbeddingEngine`, `PostProcessor`;
  XPC-контракт (сообщения, прогресс, отмена); реализации на FluidAudio (VAD, диаризация, эмбеддинги, Parakeet);
  фейковая реализация всех протоколов
- Потребляет контракты: интерфейс каталога моделей (пути к моделям приходят снаружи), DTO `Transcript`
- Запрещено: скачивать модели и ходить в сеть (это `model-manager`), знать о БД и о календаре

### МОДУЛЬ: gigaam
- Слой: движок
- Процесс: XPC-сервис
- Каталоги: `Sources/GigaAM/`, `Tests/GigaAMTests/`
- Владелец: DEV-2
- Реализует контракты: `TranscriptionEngine` для роли ASR-ru (этап 1 — sherpa-onnx на CPU; этап 2, вне Среза 1 — CoreML на ANE):
  mel, CTC-декодер, пословные таймстампы, нарезка по VAD, уверенность по токенам
- Потребляет контракты: интерфейс каталога моделей
- Запрещено: собственная диаризация и VAD (берутся из `engine-xpc`), сетевые обращения

### МОДУЛЬ: model-manager
- Слой: домен + адаптер сети
- Процесс: App
- Каталоги: `Sources/ModelManager/`, `Tests/ModelManagerTests/`
- Владелец: DEV-2
- Реализует контракты: интерфейс каталога моделей (манифест, роли, состояния, sha256, профили транскрибации)
- Потребляет контракты: репозитории `storage`
- Запрещено: загружать модели в память и исполнять инференс; знать внутренности движков

### МОДУЛЬ: attribution
- Слой: домен
- Процесс: App
- Каталоги: `Sources/Attribution/`, `Tests/AttributionTests/`
- Владелец: DEV-2
- Реализует контракты: интерфейс атрибуции (кластеры → участники, `confidence` и `source` на каждое назначение),
  словарь имён и постправка
- Потребляет контракты: DTO `Transcript`, репозитории `storage`, `EmbeddingEngine`
- Запрещено: импорт UI; молчаливая перезапись правок пользователя

### МОДУЛЬ: app-ui
- Слой: UI
- Процесс: App
- Каталоги: `App/`, `Tests/AppUITests/`
- Владелец: DEV-3
- Реализует контракты: composition root (связывание портов с реализациями), меню-бар, окно встреч,
  просмотр транскрипта, настройки, мастер прав
- Потребляет контракты: фасад приложения для UI (контракт чтения и команд), все порты — только через домен
- Запрещено: прямые обращения к `storage`, к движку и к системным адаптерам мимо домена; бизнес-логика во вью-моделях

### МОДУЛЬ: plugin-graph
- Слой: плагин
- Процесс: внешний
- Каталоги: `Plugins/graph/`
- Владелец: DEV-2
- Реализует контракты: протокол плагина календаря по stdio JSON-RPC (MSAL, delta-синхронизация)
- Потребляет контракты: сервисы хоста
- Запрещено: хранить секреты на диске (только через `secrets` хоста)
- **Вне Среза 1.**

## 4. Зависимости между модулями

Стрелка — «потребляет контракт». Ни одной стрелки против слоя: адаптеры и UI зависят от домена, домен — ни от кого.

```
app-ui ──► domain-core ◄── calendar-hub ──► storage
   │            ▲                ▲              ▲
   │            │                │              │
   └────────────┘         calendar-eventkit     ├── attribution ──► engine-xpc ──► gigaam
                                                └── model-manager        ▲
capture ──► domain-core                                                  │
permissions ──► domain-core                            engine-xpc ◄── model-manager (пути к моделям)
detector ──► domain-core
```

## 5. Планируемые контракты Среза 1

Нумерация и порядок написания. Контракты, не зависящие от спайков, пишутся сразу; `C-004` и детали `C-011`
дожидаются фактов из спайков захвата и GigaAM.

| № | Контракт | Реализатор | Потребители | Ждёт спайка |
| -- | -- | -- | -- | -- |
| C-001 | DTO `MeetingEvent` | domain-core | calendar-hub, calendar-eventkit, storage, app-ui | нет |
| C-002 | DTO `RecordingManifest` | domain-core | capture, storage, engine-xpc | нет |
| C-003 | DTO `Transcript` | domain-core | engine-xpc, gigaam, attribution, storage, app-ui | нет |
| C-004 | `AudioCapturePort` | domain-core | capture, app-ui | **да** (R1, R2, R6, R9) |
| C-005 | `CalendarPort` | domain-core | calendar-hub, app-ui | нет |
| C-006 | Протокол плагина календаря (JSON-RPC + Swift-зеркало) | domain-core | calendar-hub, calendar-eventkit, plugin-graph | нет |
| C-007 | `PermissionsPort` | domain-core | permissions, app-ui | нет |
| C-008 | `PowerPort` | domain-core | permissions, capture | нет |
| C-009 | `ProcessMonitorPort` + `JoinInfo` | domain-core | detector, calendar-hub | нет |
| C-010 | Схема SQLite и репозитории | storage | все потребители данных | нет |
| C-011 | Протоколы движка (`TranscriptionEngine`, `DiarizationEngine`, `EmbeddingEngine`, `PostProcessor`) | engine-xpc | attribution, domain-core, gigaam | **частично** (R12: таймстампы) |
| C-012 | XPC-контракт: сообщения, прогресс, отмена | engine-xpc | domain-core | нет |
| C-013 | Интерфейс `JobQueue` | domain-core | storage, engine-xpc, attribution | нет |
| C-014 | Интерфейс каталога моделей и формат манифеста | model-manager | engine-xpc, gigaam, app-ui | нет |
| C-015 | Интерфейс атрибуции | attribution | domain-core, app-ui | нет |
| C-016 | Фасад приложения для UI | domain-core | app-ui | нет |
| C-017 | Раскладка репозитория и правила сборки | архитектор | все | нет |

## 6. Что карта сознательно не решает

- Модуль `plugin-graph` и всё, что вне Среза 1 (профили спикеров, профили транскрибации, облачные движки,
  CoreML-порт GigaAM, резюме), получает владельца в своём срезе.
- Спайки (`spikes/`) не принадлежат модулям: у них свой владелец на задачу, результат — измерения и выводы,
  а не код в продукт.
