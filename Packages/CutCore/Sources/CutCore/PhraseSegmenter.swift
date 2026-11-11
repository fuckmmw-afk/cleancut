import Foundation

/// Склеивает слова с таймкодами во фразы по пунктуации и паузам.
public enum PhraseSegmenter {

    public struct Options: Sendable {
        /// Пауза между словами, после которой начинается новая фраза.
        public var maxGap: Double
        /// Мягкий предел длины фразы в словах: дальше режем по запятой или по любой заметной паузе.
        public var softWordLimit: Int
        public var hardWordLimit: Int

        public init(maxGap: Double = 0.6, softWordLimit: Int = 22, hardWordLimit: Int = 40) {
            self.maxGap = maxGap
            self.softWordLimit = softWordLimit
            self.hardWordLimit = hardWordLimit
        }
    }

    /// Чистит слова от Whisper: убирает пустые и служебные токены, чинит таймкоды.
    public static func sanitize(_ words: [Word]) -> [Word] {
        var result: [Word] = []
        for word in words.sorted(by: { $0.start < $1.start }) {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !(text.hasPrefix("<|") && text.hasSuffix("|>")) else { continue }
            guard word.start.isFinite, word.end.isFinite else { continue }
            var start = max(0, word.start)
            var end = max(start, word.end)
            if let last = result.last {
                // Знак препинания, пришедший отдельным токеном, приклеиваем к предыдущему слову.
                if text.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) }) {
                    result[result.count - 1].text += text
                    continue
                }
                start = max(start, last.start)
                end = max(end, start)
            }
            result.append(Word(text: text, start: start, end: end))
        }
        return result
    }

    public static func phrases(from words: [Word], options: Options = Options()) -> [Phrase] {
        var phrases: [Phrase] = []
        var first = 0

        func flush(upTo end: Int) {
            guard end > first else { return }
            let slice = words[first..<end]
            phrases.append(
                Phrase(
                    id: phrases.count + 1,
                    start: slice.first!.start,
                    end: slice.map(\.end).max() ?? slice.last!.end,
                    text: slice.map(\.text).joined(separator: " "),
                    firstWord: first,
                    wordCount: end - first))
            first = end
        }

        for index in words.indices {
            let word = words[index]
            let count = index - first + 1
            let isLast = index == words.count - 1
            let gap = isLast ? 0 : max(0, words[index + 1].start - word.end)

            let endsSentence = word.text.last.map { ".?!…".contains($0) } ?? false
            let endsClause = word.text.last.map { ",;:—".contains($0) } ?? false

            if isLast || endsSentence || gap >= options.maxGap {
                flush(upTo: index + 1)
            } else if count >= options.softWordLimit, endsClause || gap >= options.maxGap / 2 {
                flush(upTo: index + 1)
            } else if count >= options.hardWordLimit {
                flush(upTo: index + 1)
            }
        }
        return phrases
    }
}
