//  GigaAMAudioSource — порт чтения аудио: длительность и потоковое чтение диапазона.
//
//  Модуль: gigaam · Владелец: DEV-2 · Слой: движок
//
//  Реализацию (чтение файла дорожки) даёт XPC-сервис на Mac (Z6); ядро остаётся на Linux.
//  Позиции — время в файле (кадр 0 = 0 мс), без `AudioRef.offsetMs`: сдвиг на шкалу записи
//  прибавляет движок (инвариант 16 C-011). Ошибки: `EngineError.audioUnreadable` — файла нет или
//  чтение оборвалось, `EngineError.unsupportedRequest` — заголовок не совпал с `AudioRef`
//  (инвариант 17 C-011); движок пропускает оба как есть.

import EngineKit

public protocol GigaAMAudioSource: Sendable {
    /// Длительность файла дорожки, мс.
    func durationMs(of audio: AudioRef) throws -> Int

    /// PCM 16 кГц, моно, Float32 для диапазона `[fromMs; toMs)` времени в файле; конец за концом
    /// файла обрезается по концу файла.
    func read(_ audio: AudioRef, fromMs: Int, toMs: Int) throws -> [Float]
}
