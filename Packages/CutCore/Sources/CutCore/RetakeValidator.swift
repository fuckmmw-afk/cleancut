import Foundation

/// Проверяет решения LLM по тексту и отбрасывает те, что не подтверждаются транскриптом.
///
/// Маленькая модель охотно вырезает нормальные фразы. Поэтому дубль принимается, только если у него есть
/// более поздняя «хорошая» версия рядом и она действительно повторяет его слова.
public enum RetakeValidator {

    public struct Options: Sendable {
        /// Насколько дальше по тексту может стоять заменяющая фраза.
        public var maxPhraseDistance: Int
        public var maxSecondsGap: Double
        /// Какая доля значимых слов вырезаемой фразы должна найтись в заменяющей.
        public var minCoverage: Double
        /// Фраза-«мусор» без явных маркеров принимается, только если она не длиннее этого.
        public var maxGarbageWords: Int

        public init(
            maxPhraseDistance: Int = 8, maxSecondsGap: Double = 90, minCoverage: Double = 0.5,
            maxGarbageWords: Int = 4
        ) {
            self.maxPhraseDistance = maxPhraseDistance
            self.maxSecondsGap = maxSecondsGap
            self.minCoverage = minCoverage
            self.maxGarbageWords = maxGarbageWords
        }
    }

    public enum Verdict: Equatable, Sendable {
        case accepted
        case rejected(String)
    }

    public struct Result: Sendable, Equatable {
        public var accepted: [Removal]
        /// Предложения модели, которые не прошли проверку, с причиной.
        public var rejected: [(removal: Removal, why: String)]

        public static func == (lhs: Result, rhs: Result) -> Bool {
            lhs.accepted == rhs.accepted && lhs.rejected.map(\.removal) == rhs.rejected.map(\.removal)
        }
    }

    static let stopWords: Set<String> = [
        "и", "а", "но", "в", "во", "на", "с", "со", "к", "ко", "о", "об", "у", "по", "за", "из", "от", "до", "для",
        "не", "ни", "же", "ли", "бы", "то", "это", "этот", "эта", "эти", "вот", "ну", "так", "как", "что", "чтобы",
        "я", "ты", "он", "она", "оно", "мы", "вы", "они", "мне", "меня", "нас", "вас", "их", "его", "ее", "её",
        "да", "нет", "тут", "там", "еще", "ещё", "уже", "все", "всё", "вообще", "короче", "типа", "значит", "просто",
        "э", "эм", "ээ", "м", "мм", "ага", "угу", "про", "при", "под", "над", "без", "через", "или", "если", "тоже",
        "также", "когда", "есть", "был", "была", "было", "будет", "мой", "моя", "наш", "ваш", "свой",
    ]

    /// Маркеры служебных реплик: такую фразу можно считать мусором и без замены.
    static let markers: [String] = [
        "еще раз", "заново", "сначала", "стоп", "дубль", "не так", "бля", "блин", "черт", "сука", "епт",
        "погоди", "секунду", "давай еще", "переснять", "перезапишу",
    ]

    /// Слова фразы без пунктуации, в нижнем регистре, «ё» → «е».
    public static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Значимые слова, обрезанные до основы: «монтаже» и «монтаж» совпадут.
    static func stems(_ text: String) -> [String] {
        tokens(text).filter { !stopWords.contains($0) }.map { $0.count > 5 ? String($0.prefix(5)) : $0 }
    }

    /// Доля значимых слов `earlier`, которые встречаются в `later`.
    public static func coverage(of earlier: String, in later: String) -> Double {
        let source = stems(earlier)
        guard !source.isEmpty else { return 0 }
        let target = Set(stems(later))
        return Double(source.filter { target.contains($0) }.count) / Double(source.count)
    }

    static func hasMarker(_ text: String) -> Bool {
        let normalized = " " + tokens(text).joined(separator: " ") + " "
        return markers.contains { normalized.contains(" " + $0 + " ") || normalized.contains(" " + $0) }
    }

    public static func verdict(
        _ removal: Removal, phrases byID: [Int: Phrase], order: [Int], options: Options = Options()
    ) -> Verdict {
        guard let phrase = byID[removal.id] else { return .rejected("нет такой фразы") }
        let words = tokens(phrase.text)

        switch removal.reason {
        case .garbage:
            if hasMarker(phrase.text), words.count <= 12 { return .accepted }
            if words.count <= options.maxGarbageWords, stems(phrase.text).count <= 1 { return .accepted }
            // Модель может назвать мусором неудачную попытку: проверим как дубль.
            if let kept = removal.kept, case .accepted = repeatVerdict(phrase, kept, byID, order, options) {
                return .accepted
            }
            return .rejected("похоже на обычную фразу")

        case .retake, .falseStart:
            guard let kept = removal.kept else {
                // Без указания замены принимаем только короткие служебные реплики.
                if hasMarker(phrase.text), words.count <= 6 { return .accepted }
                return .rejected("модель не указала, какая фраза заменяет эту")
            }
            return repeatVerdict(phrase, kept, byID, order, options)
        }
    }

    private static func repeatVerdict(
        _ phrase: Phrase, _ keptID: Int, _ byID: [Int: Phrase], _ order: [Int], _ options: Options
    ) -> Verdict {
        guard let kept = byID[keptID], let from = order.firstIndex(of: phrase.id),
            let to = order.firstIndex(of: keptID)
        else { return .rejected("замена не найдена") }
        guard to > from else { return .rejected("замена должна идти после дубля") }
        guard to - from <= options.maxPhraseDistance, kept.start - phrase.end <= options.maxSecondsGap else {
            return .rejected("замена слишком далеко")
        }

        // Повтор может растянуться на две фразы, поэтому сравниваем с заменой и следующей за ней.
        var laterText = kept.text
        if to + 1 < order.count, let next = byID[order[to + 1]] { laterText += " " + next.text }

        let significant = stems(phrase.text)
        if significant.isEmpty {
            // «Ну вот», «Так, а» и подобные обрывки перед новой попыткой.
            return tokens(phrase.text).count <= 3 ? .accepted : .rejected("нечего сравнивать")
        }
        let value = coverage(of: phrase.text, in: laterText)
        // Для очень коротких обрывков хватит одного общего слова в начале замены.
        if significant.count <= 2, value > 0 { return .accepted }
        return value >= options.minCoverage
            ? .accepted : .rejected("слова не совпадают с заменой (\(Int(value * 100))%)")
    }

    public static func validate(_ removals: [Removal], phrases: [Phrase], options: Options = Options()) -> Result {
        let byID = Dictionary(phrases.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let order = phrases.map(\.id)
        var result = Result(accepted: [], rejected: [])
        for removal in removals {
            switch verdict(removal, phrases: byID, order: order, options: options) {
            case .accepted: result.accepted.append(removal)
            case .rejected(let why): result.rejected.append((removal, why))
            }
        }
        return result
    }
}
