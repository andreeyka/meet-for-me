//  SherpaGigaAMRecognizerConfigTests — IR-156 (MEE-507, MEE-512): конфигурация распознавателя
//  собирается C-структурами вручную, без Swift-обёртки пакета sherpa-onnx.
//
//  Модуль: gigaam · Владелец: DEV-2
//
//  Без модели, идёт в CI. Проверяет, что поля конфигурации совпадают с тем, что ставила обёртка
//  (`nemo_ctc`, 64 признака, 16 кГц, 4 потока, CPU, `greedy_search`), и что строки живы и
//  равны исходным внутри `withRecognizerConfig` — риск ошибки памяти, названный в решении IR-156.
//  Поведение на модели — `SherpaGigaAMRecognizerModelTests` (Mac РП) и прогон Z6.

import Foundation
@testable import GigaAMSherpa
import XCTest

final class SherpaGigaAMRecognizerConfigTests: XCTestCase {

    func testConfigCarriesWrapperValues() {
        let model = "/путь/к модели/model.int8.onnx"
        let tokens = "/путь/к модели/tokens.txt"
        SherpaGigaAMRecognizer.withRecognizerConfig(model: model, tokens: tokens) { pointer in
            let config = pointer.pointee
            XCTAssertEqual(config.feat_config.sample_rate, 16_000)
            XCTAssertEqual(config.feat_config.feature_dim, 64)
            XCTAssertEqual(string(config.model_config.nemo_ctc.model), model)
            XCTAssertEqual(string(config.model_config.tokens), tokens)
            XCTAssertEqual(config.model_config.num_threads, 4)
            XCTAssertEqual(config.model_config.debug, 0)
            XCTAssertEqual(string(config.model_config.provider), "cpu")
            XCTAssertEqual(string(config.model_config.model_type), "nemo_ctc")
            XCTAssertEqual(string(config.model_config.modeling_unit), "cjkchar")
            XCTAssertEqual(string(config.decoding_method), "greedy_search")
            XCTAssertEqual(config.max_active_paths, 4)
            XCTAssertEqual(config.hotwords_score, 1.5)
            XCTAssertEqual(config.lm_config.scale, 1.0)
            XCTAssertEqual(config.blank_penalty, 0)
        }
    }

    // Прочие модели и опции не заданы: нулевые указатели C API заменяет своими умолчаниями,
    // и ни одно поле чужой модели не должно указывать на наши строки.
    func testOtherModelsAreUnset() {
        SherpaGigaAMRecognizer.withRecognizerConfig(model: "m", tokens: "t") { pointer in
            let config = pointer.pointee
            XCTAssertNil(config.model_config.transducer.encoder)
            XCTAssertNil(config.model_config.paraformer.model)
            XCTAssertNil(config.model_config.whisper.encoder)
            XCTAssertNil(config.model_config.sense_voice.model)
            XCTAssertNil(config.model_config.bpe_vocab)
            XCTAssertNil(config.lm_config.model)
            XCTAssertNil(config.hotwords_file)
            XCTAssertNil(config.rule_fsts)
            XCTAssertNil(config.rule_fars)
        }
    }

    // Строки — отдельные копии на каждый вызов: ни одна не делит память с другой.
    func testStringsAreDistinctCopies() {
        SherpaGigaAMRecognizer.withRecognizerConfig(model: "same", tokens: "same") { pointer in
            let config = pointer.pointee
            XCTAssertNotEqual(config.model_config.nemo_ctc.model, config.model_config.tokens)
        }
    }

    func testBodyResultAndErrorPassThrough() {
        XCTAssertEqual(SherpaGigaAMRecognizer.withRecognizerConfig(model: "m", tokens: "t") { _ in 42 }, 42)
        struct Marker: Error {}
        XCTAssertThrowsError(
            try SherpaGigaAMRecognizer.withRecognizerConfig(model: "m", tokens: "t") { _ in throw Marker() }
        ) { XCTAssertTrue($0 is Marker) }
    }

    private func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        pointer.map { String(cString: $0) }
    }
}
