import Foundation

/// Чистит транскрипт Whisper перед разметкой и показывает речь, которую Whisper пропустил.
public enum TranscriptCleaner {

    /// Текст слова-заглушки для речи без расшифровки.
    public static let unknownText = "[…]"

    public static func isUnknown(_ word: Word) -> Bool { word.text == unknownText }

    public struct Result: Sendable, Equatable {
        public var words: [Word]
        /// Выброшенные куски текста, для журнала.
        public var removed: [String]
        /// Сколько заглушек добавлено.
        public var unknownCount: Int
    }

    /// Фразы, которые Whisper выдумывает на тишине и шуме: он учился на субтитрах с титрами.
    /// Убираются всегда.
    static let strongPatterns: [[String]] = [
        ["продолжение", "следует"],
        ["субтитры"], ["субтитров"], ["субтитрами"],
        ["dimatorzok"], ["amara"],
    ]

    /// Такие фразы человек может сказать и сам, поэтому они убираются, только если звучат вне речи.
    static let weakPatterns: [[String]] = [
        ["спасибо", "за", "просмотр"],
        ["подписывайтесь", "на", "канал"],
        ["ставьте", "лайки"],
        ["до", "новых", "встреч"],
    ]

    public static func clean(
        _ words: [Word], speech: [TimeRange], duration: Double, minUnknown: Double = 0.35
    ) -> Result {
        var removed: [String] = []
        var kept = removeHallucinations(words, speech: speech, removed: &removed)

        // Таймкоды за концом видео: Whisper дописывает последнее окно до 30 секунд.
        kept = kept.compactMap { word in
            guard duration > 0 else { return word }
            if word.start >= duration - 0.01 {
                removed.append(word.text)
                return nil
            }
            var word = word
            word.end = min(word.end, duration)
            return word
        }

        // Слова нулевой длины на тишине — тоже выдумка.
        if !speech.isEmpty {
            kept.removeAll { word in
                let empty = word.end - word.start < 0.02
                let outside = !speech.contains { $0.overlaps(TimeRange(start: word.start - 0.2, end: word.end + 0.2)) }
                if empty && outside { removed.append(word.text) }
                return empty && outside
            }
        }

        let unknown = unknownSpeech(words: kept, speech: speech, minDuration: minUnknown)
        let merged = (kept + unknown).sorted { $0.start < $1.start }
        return Result(words: merged, removed: removed, unknownCount: unknown.count)
    }

    // MARK: - Галлюцинации

    static func removeHallucinations(_ words: [Word], speech: [TimeRange], removed: inout [String]) -> [Word] {
        let tokens = words.map { RepeatFinder.normalize($0.text) }
        var drop = IndexSet()

        func sentenceRange(around index: Int) -> Range<Int> {
            var start = index
            while start > 0, !endsSentence(words[start - 1].text), index - start < 8 { start -= 1 }
            var end = index
            while end < words.count - 1, !endsSentence(words[end].text), end - index < 8 { end += 1 }
            return start..<(end + 1)
        }

        func matches(_ pattern: [String], at index: Int) -> Bool {
            guard index + pattern.count <= tokens.count else { return false }
            return pattern.indices.allSatisfy { tokens[index + $0] == pattern[$0] }
        }

        for index in words.indices {
            for pattern in strongPatterns where matches(pattern, at: index) {
                if pattern.count >= 2 {
                    // «Продолжение следует» прилипает к концу настоящей фразы: убираем только его.
                    drop.insert(integersIn: index..<(index + pattern.count))
                } else {
                    // Титры: «Субтитры сделал DimaTorzok», «Редактор субтитров А. Семкин» — всё предложение.
                    drop.insert(integersIn: sentenceRange(around: index))
                }
            }
            for pattern in weakPatterns where matches(pattern, at: index) {
                let range = index..<(index + pattern.count)
                let span = TimeRange(start: words[range.lowerBound].start, end: words[range.upperBound - 1].end)
                let inSpeech = speech.isEmpty || speech.contains { $0.overlaps(span) }
                if !inSpeech { drop.insert(integersIn: range) }
            }
        }

        guard !drop.isEmpty else { return words }
        for range in drop.rangeView {
            removed.append(words[range].map(\.text).joined(separator: " "))
        }
        return words.indices.filter { !drop.contains($0) }.map { words[$0] }
    }

    static func endsSentence(_ text: String) -> Bool {
        text.last.map { ".?!…".contains($0) } ?? false
    }

    // MARK: - Речь без слов

    /// Куски речи (по детектору), на которые не попало ни одно слово.
    ///
    /// Whisper «чистит» речь: повторённое слово, оговорку или заикание он пишет один раз или не пишет вовсе.
    /// Звук при этом остаётся, и без заглушки его нельзя ни увидеть, ни вырезать вручную.
    public static func unknownSpeech(
        words: [Word], speech: [TimeRange], minDuration: Double = 0.35, margin: Double = 0.06
    ) -> [Word] {
        guard !speech.isEmpty else { return [] }
        let covered = CutPlanner.merge(
            words.map { TimeRange(start: $0.start - margin, end: $0.end + margin) })
        var result: [Word] = []
        for range in CutPlanner.merge(speech) {
            var cursor = range.start
            for cover in covered where cover.end > range.start && cover.start < range.end {
                if cover.start - cursor >= minDuration {
                    result.append(Word(text: unknownText, start: cursor, end: cover.start))
                }
                cursor = max(cursor, cover.end)
            }
            if range.end - cursor >= minDuration {
                result.append(Word(text: unknownText, start: cursor, end: range.end))
            }
        }
        return result
    }
}
