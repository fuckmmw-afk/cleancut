import Foundation

/// Находит повторы по словам, без LLM. Во всех случаях остаётся ПОСЛЕДНЯЯ версия.
///
/// - Рестарт и заикание внутри предложения: «мы по… мы поговорим», «я я пошёл»,
///   «сегодня я хочу, сегодня я хочу рассказать». Вырезается брошенная попытка.
/// - Одинаковые предложения: человек произнёс фразу, потом сказал её ещё раз. Вырезаются ранние.
public enum RepeatFinder {

    public struct Options: Sendable {
        /// Насколько далеко (в словах) может начаться новая попытка.
        public var maxRestartWords: Int
        public var maxRestartSeconds: Double
        /// Какая доля слов брошенной попытки должна повториться сразу после неё.
        public var minRestartCoverage: Double
        /// Насколько далеко (во фразах) ищется повтор предложения.
        public var maxPhraseDistance: Int
        public var maxPhraseSeconds: Double
        /// Насколько похожими должны быть предложения.
        public var minPhraseSimilarity: Double

        public init(
            maxRestartWords: Int = 15, maxRestartSeconds: Double = 15, minRestartCoverage: Double = 0.75,
            maxPhraseDistance: Int = 6, maxPhraseSeconds: Double = 90, minPhraseSimilarity: Double = 0.7
        ) {
            self.maxRestartWords = maxRestartWords
            self.maxRestartSeconds = maxRestartSeconds
            self.minRestartCoverage = minRestartCoverage
            self.maxPhraseDistance = maxPhraseDistance
            self.maxPhraseSeconds = maxPhraseSeconds
            self.minPhraseSimilarity = minPhraseSimilarity
        }
    }

    public struct Match: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// Брошенная попытка внутри предложения или на стыке фраз.
            case restart
            /// Целое предложение, которое потом сказано заново.
            case sentence
        }

        public var kind: Kind
        /// Слова, которые нужно вырезать.
        public var words: Range<Int>
        /// Первое слово версии, которая остаётся.
        public var keptWord: Int
        /// Для повтора предложения: какая фраза вырезается и какая остаётся.
        public var phraseID: Int?
        public var keptPhraseID: Int?
    }

    static let fillers: Set<String> = ["э", "ээ", "эм", "м", "мм", "ну", "вот", "так", "короче", "типа", "значит", "это"]

    /// Слово для сравнения: нижний регистр, «ё» → «е», без пунктуации.
    static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// Совпадают ли слова, с учётом оборванного слова («погово» и «поговорим») и окончаний.
    static func same(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        let shorter = lhs.count <= rhs.count ? lhs : rhs
        let longer = lhs.count <= rhs.count ? rhs : lhs
        // Оборванное слово: хотя бы 3 буквы и начало длинного.
        if shorter.count >= 3, longer.hasPrefix(shorter) { return true }
        // Разные окончания одного слова: общая основа из 5 букв.
        return shorter.count >= 6 && longer.count >= 6 && shorter.prefix(5) == longer.prefix(5)
    }

    // MARK: - Рестарты внутри речи

    public static func restarts(in words: [Word], options: Options = Options()) -> [Match] {
        let tokens = words.map { normalize($0.text) }
        var matches: [Match] = []
        var index = 0

        while index < tokens.count {
            guard !tokens[index].isEmpty else {
                index += 1
                continue
            }
            // Берём самую дальнюю подходящую новую попытку: тогда цепочка «а, а, а б» режется одним куском.
            var best: Int?
            let upper = min(tokens.count - 1, index + options.maxRestartWords)
            if index + 1 <= upper {
                for next in (index + 1)...upper {
                    guard words[next].start - words[index].start <= options.maxRestartSeconds else { break }
                    guard same(tokens[index], tokens[next]) else { continue }
                    if isRestart(tokens, from: index, to: next, options: options) { best = next }
                }
            }
            if let next = best {
                matches.append(Match(kind: .restart, words: index..<next, keptWord: next))
                index = next
            } else {
                index += 1
            }
        }
        return matches
    }

    /// Брошенная попытка `tokens[from..<to]` почти целиком повторяется сразу после неё.
    static func isRestart(_ tokens: [String], from: Int, to: Int, options: Options) -> Bool {
        let attempt = Array(tokens[from..<to]).filter { !$0.isEmpty }
        guard !attempt.isEmpty else { return false }
        let laterEnd = min(tokens.count, to + attempt.count + 3)
        let later = Array(tokens[to..<laterEnd])

        // Короткая попытка («я», «мы по») должна повториться полностью и подряд.
        if attempt.count <= 2 {
            let meaningful = attempt.filter { !fillers.contains($0) }
            // «Ну, ну» и «э, э» — это не рестарт, а паразиты; их не трогаем.
            guard !meaningful.isEmpty || attempt.count == 1 else { return false }
            var position = 0
            for token in attempt where !fillers.contains(token) || token == attempt.first {
                guard position < later.count, same(token, later[position]) else { return false }
                position += 1
            }
            return true
        }

        // Длинная попытка: большая часть её слов есть в новой версии, и та начинается с тех же двух слов.
        guard later.count >= 2, same(attempt[0], later[0]) else { return false }
        let secondAttempt = attempt.dropFirst().first { !fillers.contains($0) }
        let secondLater = later.dropFirst().first { !fillers.contains($0) }
        if let secondAttempt, let secondLater, !same(secondAttempt, secondLater) { return false }
        let found = attempt.filter { token in later.contains { same(token, $0) } }.count
        return Double(found) / Double(attempt.count) >= options.minRestartCoverage
    }

    // MARK: - Повторы предложений

    static func stems(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map { normalize(String($0)) }
            .filter { !$0.isEmpty && !RetakeValidator.stopWords.contains($0) }
    }

    /// Похожесть фраз: доля значимых слов более короткой фразы, найденных в другой.
    public static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = stems(lhs)
        let right = stems(rhs)
        guard left.count >= 2, right.count >= 2 else { return 0 }
        let (shorter, longer) = left.count <= right.count ? (left, right) : (right, left)
        let found = shorter.filter { token in longer.contains { same(token, $0) } }.count
        // Если одна фраза сильно длиннее, это скорее развитие мысли, чем повтор.
        let lengthRatio = Double(shorter.count) / Double(longer.count)
        guard lengthRatio >= 0.4 else { return 0 }
        return Double(found) / Double(shorter.count)
    }

    public static func sentenceRepeats(in phrases: [Phrase], options: Options = Options()) -> [Match] {
        var matches: [Match] = []
        for (index, phrase) in phrases.enumerated() {
            let upper = min(phrases.count - 1, index + options.maxPhraseDistance)
            guard index + 1 <= upper else { continue }
            // Берём самую позднюю похожую фразу: остаться должна последняя версия.
            var kept: Phrase?
            for later in phrases[(index + 1)...upper] {
                guard later.start - phrase.end <= options.maxPhraseSeconds else { break }
                if similarity(phrase.text, later.text) >= options.minPhraseSimilarity { kept = later }
            }
            if let kept {
                matches.append(
                    Match(
                        kind: .sentence, words: phrase.wordRange, keptWord: kept.firstWord, phraseID: phrase.id,
                        keptPhraseID: kept.id))
            }
        }
        return matches
    }

    /// Все повторы: сначала целые предложения, затем рестарты в том, что осталось.
    public static func find(words: [Word], phrases: [Phrase], options: Options = Options()) -> [Match] {
        let sentences = sentenceRepeats(in: phrases, options: options)
        var covered = IndexSet()
        for match in sentences { covered.insert(integersIn: match.words) }
        let restarts = restarts(in: words, options: options).filter { match in
            !match.words.allSatisfy { covered.contains($0) }
        }
        return (sentences + restarts).sorted { $0.words.lowerBound < $1.words.lowerBound }
    }
}
