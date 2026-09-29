//  CatalogFixtures — именованные `catalog.json` для тестов (C-014 v6 «Фейк для тестов»; MEE-442).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  Восемь фикстур, названных контрактом: полный валидный каталог; неизвестный
//  `schemaVersion`; нет ключа `schemaVersion`; повторяющийся ключ; модель с битым `sha256`;
//  модель с `minChip == .m4`; профиль, ссылающийся на несуществующую модель; профиль
//  `isBuiltIn == false`. Плюс девятая — повторяющаяся пара (`id`, `version`) (инв. 2, К2).
//
//  Каждая фикстура — СЫРЫЕ БАЙТЫ (`Data`), а не только разобранное значение (план MEE-436
//  §8 п. 6): отсутствующий и повторяющийся ключ `Codable`-значением не выражаются. Там, где
//  фикстура разбирается, есть и значение (`validCatalog`, `minChipM4Catalog`,
//  `profileWithUnknownModelCatalog`) — разобранное тем же `DomainJSON`, что и в продукте.
//
//  `sha256` здесь — формально верные строки, а не хеши каких-то байт: фикстуры описывают
//  КАТАЛОГ, файлов моделей за ними нет (C-014 «Что вне контракта»).

import Foundation
import DomainCore

public enum CatalogFixtures {

    // MARK: - Сырые байты

    /// Полный валидный каталог: две модели (asr из трёх файлов-описаний и vad), два профиля.
    public static let validCatalogJSON = Data(validCatalogText.utf8)

    /// `schemaVersion: 2` и заодно битое поле внутри `models[]` (`minChip: "m9"`) — К4:
    /// отказ обязан назвать версию, а не поле.
    public static let unknownSchemaVersionJSON = Data(validCatalogText
        .replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2")
        .replacingOccurrences(of: "\"minChip\": \"m2\"", with: "\"minChip\": \"m9\"").utf8)

    /// Нет ключа `schemaVersion` вовсе.
    public static let missingSchemaVersionJSON = Data(validCatalogText
        .replacingOccurrences(of: "\"schemaVersion\": 1,\n", with: "").utf8)

    /// Повторяющийся ключ верхнего уровня (`generatedAt` дважды) — отказ `DomainJSON` до разбора.
    public static let duplicateKeyJSON = Data(validCatalogText
        .replacingOccurrences(of: "\"schemaVersion\": 1,",
                              with: "\"schemaVersion\": 1,\n  \"generatedAt\": \"2026-09-10T00:00:00.000Z\",").utf8)

    /// Модель с битым `sha256`: заглавные буквы и 63 символа вместо 64.
    public static let malformedSha256JSON = Data(validCatalogText
        .replacingOccurrences(of: validVocabSha256, with: malformedSha256).utf8)

    /// Модель с `minChip == .m4`.
    public static let minChipM4JSON = Data(validCatalogText
        .replacingOccurrences(of: "\"minChip\": \"m2\"", with: "\"minChip\": \"m4\"").utf8)

    /// Профиль, ссылающийся на несуществующую модель (`asrModelId`).
    public static let profileWithUnknownModelJSON = Data(validCatalogText
        .replacingOccurrences(of: "\"asrModelId\": \"gigaam-v3-e2e-ctc-int8\"",
                              with: "\"asrModelId\": \"\(unknownModelId)\"").utf8)

    /// Каталог с профилем `isBuiltIn == false` (инв. 30).
    public static let nonBuiltInProfileJSON = Data(validCatalogText
        .replacingOccurrences(of: "\"id\": \"ru-fast\",", with: "\"id\": \"\(nonBuiltInProfileId)\",")
        .replacingOccurrences(of: "\"isBuiltIn\": true\n    }\n  ]", with: "\"isBuiltIn\": false\n    }\n  ]").utf8)

    /// Две записи `models` с одной парой (`id`, `version`) (инв. 2).
    public static let duplicateModelPairJSON = Data(validCatalogText
        .replacingOccurrences(of: "\"id\": \"silero-vad\"", with: "\"id\": \"gigaam-v3-e2e-ctc-int8\"")
        .replacingOccurrences(of: "\"version\": \"5.1.0\"", with: "\"version\": \"3.0.0\"").utf8)

    // MARK: - Разобранные значения

    public static var validCatalog: ModelCatalogFile { parse(validCatalogJSON) }
    public static var minChipM4Catalog: ModelCatalogFile { parse(minChipM4JSON) }
    public static var profileWithUnknownModelCatalog: ModelCatalogFile { parse(profileWithUnknownModelJSON) }

    // MARK: - Имена, на которые ссылаются тесты

    public static let asrModelId = "gigaam-v3-e2e-ctc-int8"
    public static let vadModelId = "silero-vad"
    public static let unknownModelId = "no-such-model"
    public static let nonBuiltInProfileId = "user-made"
    public static let malformedSha256 = "ABCDEF000000000000000000000000000000000000000000000000000000000"
    public static let validVocabSha256 = "1111111111111111111111111111111111111111111111111111111111111111"

    private static func parse(_ data: Data) -> ModelCatalogFile {
        do {
            return try DomainJSON.decode(ModelCatalogFile.self, from: data)
        } catch {
            preconditionFailure("CatalogFixtures: фикстура не разбирается — \(error)")
        }
    }

    private static let validCatalogText = """
    {
      "schemaVersion": 1,
      "generatedAt": "2026-09-11T00:00:00.000Z",
      "models": [
        {
          "id": "gigaam-v3-e2e-ctc-int8",
          "version": "3.0.0",
          "role": "asr",
          "engine": "sherpaonnx",
          "runtime": "onnx",
          "displayName": "GigaAM v3 (русский)",
          "description": "Русский ASR, вариант e2e_ctc, int8",
          "sizeBytes": 236978176,
          "languages": ["ru"],
          "files": [
            {"name": "model.int8.onnx", "url": "https://cdn.example/gigaam/model.int8.onnx",
             "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
             "sizeBytes": 236716032},
            {"name": "vocab.txt", "url": "https://cdn.example/gigaam/vocab.txt",
             "sha256": "1111111111111111111111111111111111111111111111111111111111111111",
             "sizeBytes": 262144}
          ],
          "quantization": "int8",
          "minChip": "m2",
          "minRAMGB": 8,
          "recommendedFor": ["ru", "quality"]
        },
        {
          "id": "silero-vad",
          "version": "5.1.0",
          "role": "vad",
          "engine": "sherpaonnx",
          "runtime": "onnx",
          "displayName": "Silero VAD",
          "description": "Детектор речи",
          "sizeBytes": 2327524,
          "languages": [],
          "files": [
            {"name": "silero_vad.onnx", "url": "https://cdn.example/silero/silero_vad.onnx",
             "sha256": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
             "sizeBytes": 2327524}
          ],
          "minChip": "m1",
          "minRAMGB": 4,
          "recommendedFor": []
        }
      ],
      "profiles": [
        {
          "id": "ru-default",
          "displayName": "Русские встречи",
          "language": "ru",
          "asrModelId": "gigaam-v3-e2e-ctc-int8",
          "vadModelId": "silero-vad",
          "diarization": {"expectedSpeakers": null, "clusteringThreshold": 0.7, "minSegmentMs": 500},
          "isBuiltIn": true
        },
        {
          "id": "ru-fast",
          "displayName": "Быстро",
          "language": "ru",
          "asrModelId": "gigaam-v3-e2e-ctc-int8",
          "diarization": {"expectedSpeakers": 2, "clusteringThreshold": 0.5, "minSegmentMs": 300},
          "isBuiltIn": true
        }
      ]
    }
    """
}
