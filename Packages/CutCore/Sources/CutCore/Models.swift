import Foundation

/// Полуинтервал [start, end) в секундах исходного видео.
public struct TimeRange: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { max(0, end - start) }
    public var mid: Double { (start + end) / 2 }

    public func contains(_ time: Double) -> Bool { time >= start && time < end }

    public func overlaps(_ other: TimeRange) -> Bool {
        start < other.end && other.start < end
    }
}

public struct Word: Codable, Hashable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }

    public var mid: Double { (start + end) / 2 }
}

/// Фраза: подряд идущие слова. `firstWord..<firstWord + wordCount` — индексы в общем массиве слов.
public struct Phrase: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var text: String
    public var firstWord: Int
    public var wordCount: Int

    public init(id: Int, start: Double, end: Double, text: String, firstWord: Int, wordCount: Int) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.firstWord = firstWord
        self.wordCount = wordCount
    }

    public var wordRange: Range<Int> { firstWord..<(firstWord + wordCount) }
}

public enum CutKind: String, Codable, Sendable, CaseIterable {
    case pause
    case retake
    case falseStart = "false_start"
    case garbage
    case manual
}

public struct Cut: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var kind: CutKind
    public var enabled: Bool
    /// Фраза, из-за которой появился рез (для дублей и фальстартов).
    public var phraseID: Int?
    /// Пояснение для экрана ревью: какая фраза заменяет эту или почему предложение модели не принято.
    public var note: String?

    public init(
        id: UUID = UUID(), start: Double, end: Double, kind: CutKind, enabled: Bool = true,
        phraseID: Int? = nil, note: String? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.kind = kind
        self.enabled = enabled
        self.phraseID = phraseID
        self.note = note
    }

    public var range: TimeRange { TimeRange(start: start, end: end) }
}

/// Решение детектора дублей по одной фразе.
public struct Removal: Codable, Hashable, Sendable {
    public enum Reason: String, Codable, Sendable, CaseIterable {
        case retake
        case falseStart = "false_start"
        case garbage

        public var cutKind: CutKind {
            switch self {
            case .retake: .retake
            case .falseStart: .falseStart
            case .garbage: .garbage
            }
        }
    }

    public var id: Int
    public var reason: Reason
    /// Более поздняя фраза, которая заменяет эту (для дублей и фальстартов).
    public var kept: Int?

    public init(id: Int, reason: Reason, kept: Int? = nil) {
        self.id = id
        self.reason = reason
        self.kept = kept
    }
}
