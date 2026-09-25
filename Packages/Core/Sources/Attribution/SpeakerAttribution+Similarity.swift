//  SpeakerAttribution+Similarity — числовые примитивы, общие для правила 2 (косинусное
//  сходство эмбеддингов, инв. 17) и правила постправки §6 (фонетическая близость слова к
//  форме имени). Контракт не называет алгоритм фонетической близости — только пороговое
//  поведение («если максимальная близость >= nameSimilarityMin»); здесь она посчитана
//  нормированным расстоянием Левенштейна по регистронезависимому сравнению символов —
//  простой, детерминированный выбор без внешних зависимостей (Linux, C-015 инв. 18).

import Foundation

extension SpeakerAttribution {
    /// Инв. 17: одинаковая длина векторов — предпосылка сравнения, не часть этой функции;
    /// вызывающая сторона обязана проверить длины сама и бросить `embeddingModelMismatch`.
    func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        let dot = zip(lhs, rhs).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let lhsNorm = (lhs.reduce(0.0) { $0 + Double($1) * Double($1) }).squareRoot()
        let rhsNorm = (rhs.reduce(0.0) { $0 + Double($1) * Double($1) }).squareRoot()
        guard lhsNorm > 0, rhsNorm > 0 else { return 0.0 }
        return dot / (lhsNorm * rhsNorm)
    }

    /// `1 - расстояние / длина большей строки`, регистронезависимо. `0...1`: `1.0` — точное
    /// совпадение без учёта регистра, `0.0` — ничего общего в пределах длины большей строки.
    func phoneticSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsChars = Array(lhs.lowercased())
        let rhsChars = Array(rhs.lowercased())
        if lhsChars.isEmpty, rhsChars.isEmpty { return 1.0 }
        let distance = levenshteinDistance(lhsChars, rhsChars)
        let longest = max(lhsChars.count, rhsChars.count)
        return 1.0 - Double(distance) / Double(longest)
    }

    private func levenshteinDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previousRow = Array(0...rhs.count)
        for rowIndex in 1...lhs.count {
            var currentRow = [rowIndex] + [Int](repeating: 0, count: rhs.count)
            for columnIndex in 1...rhs.count {
                let substitutionCost = lhs[rowIndex - 1] == rhs[columnIndex - 1] ? 0 : 1
                currentRow[columnIndex] = Swift.min(
                    previousRow[columnIndex] + 1,
                    currentRow[columnIndex - 1] + 1,
                    previousRow[columnIndex - 1] + substitutionCost
                )
            }
            previousRow = currentRow
        }
        return previousRow[rhs.count]
    }
}
