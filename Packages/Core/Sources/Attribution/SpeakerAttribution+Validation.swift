//  SpeakerAttribution+Validation — инв. 2, 3, 11 C-015 v9: проверки входа, общие для всех
//  трёх методов порта.

import DomainCore

extension SpeakerAttribution {
    /// Инв. 2: `segmentIds.count == transcript.segments.count`. Инв. 3: все `profiles` несут
    /// `modelVersion == input.embeddingModelVersion` — проверяется целиком до единого
    /// сравнения векторов (К3: отказ не выборочный, весь вызов).
    ///
    /// Порядок полей ошибки — выбор реализации, контракт не называет, какое поле
    /// `expected`/`actual`: здесь `expected` — то, что называет сам вход (заявленная длина/
    /// версия), `actual` — то, что найдено по факту (реальный счётчик сегментов/версия
    /// профиля), тем же порядком, что уже стоит у `embeddingModelMismatch` в другом месте.
    func validateStructure(input: AttributionInput) throws {
        guard input.segmentIds.count == input.transcript.segments.count else {
            throw AttributionError.segmentIdsMismatch(
                expected: input.segmentIds.count,
                actual: input.transcript.segments.count
            )
        }
        for profile in input.profiles where profile.modelVersion != input.embeddingModelVersion {
            throw AttributionError.embeddingModelMismatch(
                expected: input.embeddingModelVersion,
                actual: profile.modelVersion
            )
        }
    }

    /// Инв. 11, сужен IR-128: «нет в базе» — не дело порта, сверяется только с `attendees`/
    /// `me` этого же входа.
    func validateKnownPerson(_ personId: UUID, input: AttributionInput) throws {
        let known = input.attendees.contains { $0.id == personId } || input.me?.id == personId
        guard known else { throw AttributionError.unknownPerson(personId) }
    }

    /// Инв. 11: кластер обязан существовать в `transcript.speakers` этого же входа.
    func validateKnownCluster(_ cluster: Int, input: AttributionInput) throws {
        guard input.transcript.speakers.contains(where: { $0.cluster == cluster }) else {
            throw AttributionError.unknownCluster(cluster)
        }
    }
}
