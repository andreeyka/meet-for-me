//  EngineTransportFault — C-012 v9 §3.1: отказ транспорта. Объявлен здесь именно как пара
//  «код + текстовые ключи `userInfo`», а не оборачивая `NSError` — `NSError` существует и на
//  Linux, поэтому одной сборки этого модуля на `Core (Linux)` для инварианта 13 недостаточно:
//  проверка механическая, по самому объявлению (символьный граф/grep), а не только по факту
//  сборки. Отображение кода+`userInfo` в `NSError`/`TranscriptionServiceError` — сторона
//  клиента (`EngineXPCClient`, C-012 §3.2), часть 2, Core + Mac.
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (протоколы и сообщения)
//
//  Коды `1`, `2`, `3` и `errorDomain` — постоянные (инвариант 17): следующий отказ берёт
//  следующее свободное число, существующие не переезжают.

public enum EngineTransportFault: Int, Codable, Equatable, Sendable, CaseIterable {
    case protocolVersionMismatch = 1
    case messageTooLarge = 2
    case invalidRequest = 3

    public static let errorDomain: String = "MeetForMe.EngineTransport"
    public static let clientProtocolVersionKey = "clientProtocolVersion"
    public static let serviceProtocolVersionKey = "serviceProtocolVersion"
    public static let messageBytesKey = "messageBytes"
}
