//  EngineKit
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (протоколы и сообщения)
//
//  Каталог принадлежит владельцу модуля: файлы здесь изменяет только он (П1).
//  Всё, что пересекает границу модуля, описано контрактом архитектора и меняется
//  только через interface-request (П2, П6). Границы и запреты — docs/module-map.md.
//
//  MEE-390, часть 1 (Core/Linux): протоколы движка C-011 v5 §4, сообщения провода и
//  кодирование C-012 v10 §2, форма отказов транспорта §3.1, `LoopbackEngineTransport` —
//  в части, что проверяет провод. Разрешённые типы — `.github/scripts/allowed-types/
//  EngineKit.json` (объединение C-011 инв. 15 и C-012 инв. 23, 53 позиции).
//
//  Не здесь (часть 2, Core + Mac, будущая задача): `EngineXPCClient`, отображение §3.2 в
//  `TranscriptionServiceError`, точка входа сервиса `Services/TranscriptionEngineXPC/`.
//
//  Файлы: EngineValidation (ступень (в), зеркало `domain-core`'s `DomainOwner`), EngineAudio
//  (AudioRef/AudioSlice), EngineRequests (четыре входа), EngineResults (DiarizationResult+
//  Turn/EmbeddingResult), EngineOutput (MeetingOutputDraft+Kind), EngineProgressTypes
//  (EngineStage/EngineProgress), EngineErrorType (EngineError), EngineProtocols (четыре
//  протокола §4), EngineWireTypes+EngineWire (C-012 §2), EngineTransportFault (§3.1),
//  Fakes/ (пять публичных типов «Фейка для тестов» обоих контрактов).
