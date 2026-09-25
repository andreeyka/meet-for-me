//  EngineXPCServiceProtocol, EngineXPCClientProtocol — C-012 v10 §3: два собственных
//  `@objc`-протокола транспорта (инвариант 23 EngineXPCClient называет их «два собственных»
//  дословно — `allowed-types/EngineXPCClient.json`). Оба несут только `Data` — байты уже
//  прошли через `EngineWire` на стороне вызывающего; ни `EngineRequest`/`EngineReply`, ни
//  `NSXPCConnection` не пересекают границу публичной сигнатуры этого модуля (инвариант 14).
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (клиент NSXPCConnection)
//
//  ДВЕ СТОРОНЫ, ОДИН ПРОВОД. `EngineXPCServiceProtocol` — интерфейс, который экспортирует
//  СЕРВИС (`remoteObjectInterface` со стороны клиента): один универсальный метод на все шесть
//  случаев `EngineRequest` (`transcribe`/`diarize`/`embed`/`postProcess`/`cancel`/`ping`) —
//  сама форма кадра решает, что это, декодированием на той стороне, что его читает. Реплай-блок
//  того самого вызова, что запустил долгую работу (`transcribe`/`diarize`/`embed`/`postProcess`),
//  срабатывает один раз, когда для ЭТОГО `jobId` готов финальный `EngineReply` — сколько бы это
//  ни заняло; отдельный вызов `send` с кадром `.cancel(jobId)` — свой, короткий, получает
//  собственный быстрый ответ независимо от вызова, который он отменяет.
//
//  `EngineXPCClientProtocol` — интерфейс, который экспортирует КЛИЕНТ (`exportedInterface`
//  со стороны клиента, `remoteObjectInterface` со стороны сервиса): сервис зовёт его сам,
//  без ответа, чтобы протолкнуть `EngineProgressMessage` в любой момент между отправкой
//  запроса и его финальным ответом — прогресс не привязан к реплай-блоку `send`, потому что
//  один вызов `send` может породить сколько угодно сообщений прогресса до одного финального.

import Foundation

@objc public protocol EngineXPCServiceProtocol: NSObjectProtocol {
    /// `requestData` — `EngineWire.encode(EngineRequest)`. `reply` получает
    /// `EngineWire.encode(EngineReply)` при успешном разборе и исполнении, либо `nil` с
    /// `NSError` в домене `EngineTransportFault.errorDomain` при отказе транспорта (§3.1) —
    /// никогда оба сразу и никогда ни одного.
    func send(_ requestData: Data, reply: @escaping (Data?, Error?) -> Void)
}

@objc public protocol EngineXPCClientProtocol: NSObjectProtocol {
    /// `progressData` — `EngineWire.encode(EngineProgressMessage)`. Без ответа (`Void`) —
    /// сервис не ждёт подтверждения доставки, клиент вправе отбросить кадр молча (К40 ii-iii).
    func didReceiveProgress(_ progressData: Data)
}
