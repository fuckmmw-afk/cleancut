import Foundation

/// Детектор дублей без LLM: ищет фразы, которые сразу после себя имеют более полный повтор,
/// и служебные реплики вроде «ещё раз». Запасной вариант, когда модель недоступна.
public enum HeuristicRetake {

    static let markers: [String] = [
        "еще раз", "ещё раз", "заново", "сначала", "стоп", "не так", "блин", "бля", "блять", "черт", "чёрт",
    ]

    public static func normalize(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    public static func detect(_ phrases: [Phrase], lookahead: Int = 3) -> [Removal] {
        let tokens = phrases.map { normalize($0.text) }
        var removals: [Removal] = []

        for index in phrases.indices {
            let current = tokens[index]
            guard !current.isEmpty else { continue }

            // Короткая служебная реплика.
            let joined = current.joined(separator: " ")
            if current.count <= 4,
                markers.contains(where: { joined.contains($0.replacingOccurrences(of: "ё", with: "е")) })
            {
                removals.append(Removal(id: phrases[index].id, reason: .garbage))
                continue
            }

            // Более поздняя фраза начинается так же и не короче: текущая была неудачной попыткой.
            let upper = min(phrases.count, index + 1 + lookahead)
            guard index + 1 < upper else { continue }
            for next in (index + 1)..<upper {
                let later = tokens[next]
                let common = commonPrefix(current, later)
                let needed = min(3, current.count)
                if common >= max(2, needed), later.count >= current.count {
                    let isPrefixOnly = common == current.count && later.count > current.count
                    removals.append(
                        Removal(id: phrases[index].id, reason: isPrefixOnly ? .falseStart : .retake))
                    break
                }
            }
        }
        return removals
    }

    private static func commonPrefix(_ lhs: [String], _ rhs: [String]) -> Int {
        var count = 0
        while count < lhs.count, count < rhs.count, lhs[count] == rhs[count] { count += 1 }
        return count
    }
}
