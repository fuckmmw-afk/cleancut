import Foundation

/// Запрос к LLM и нарезка транскрипта на чанки.
public enum RetakePrompt {

    public struct Chunk: Sendable, Equatable {
        public var phrases: [Phrase]
        /// id фраз, которые уже были в хвосте предыдущего чанка.
        public var overlapIDs: Set<Int>

        public var ids: Set<Int> { Set(phrases.map(\.id)) }
    }

    public static let system = """
        Ты монтажёр. Тебе дают расшифровку сырого «говорящего» видео: пронумерованные фразы с таймкодами. \
        Спикер оговаривается, начинает фразу заново и повторяет дубли. Найди фразы, которые нужно вырезать.

        Правила:
        1. Если фраза или её кусок повторяется (оговорка, рестарт, «ещё раз», «заново», «бля, ещё раз»), \
        оставь ПОСЛЕДНЮЮ полную версию, а все предыдущие попытки вырежи: reason = "retake".
        2. Оборванные фразы и фальстарты, после которых мысль начата заново: reason = "false_start".
        3. Реплики не для зрителя (ругань на дубль, «так, стоп», «ещё раз», команды самому себе): reason = "garbage".
        4. Нормальные фразы не трогай. Смысл не меняй. Если сомневаешься, оставь фразу.
        5. Вырезать можно только фразу целиком, по её номеру.

        Ответ: строго один JSON-объект без пояснений и без markdown:
        {"remove":[{"id":N,"reason":"retake|false_start|garbage"}]}
        Если вырезать нечего: {"remove":[]}
        """

    public static let retryReminder = """
        Предыдущий ответ не прошёл проверку. Верни ТОЛЬКО JSON вида \
        {"remove":[{"id":N,"reason":"retake|false_start|garbage"}]}, используя только номера фраз из списка. \
        Вырезай только явные дубли и фальстарты.
        """

    public static func timecode(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let rest = total - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, rest)
    }

    public static func user(for chunk: Chunk, isRetry: Bool = false) -> String {
        var lines = ["Фразы:"]
        for phrase in chunk.phrases {
            lines.append("\(phrase.id) [\(timecode(phrase.start))–\(timecode(phrase.end))] \(phrase.text)")
        }
        lines.append("")
        lines.append(isRetry ? retryReminder : "Верни JSON со списком фраз, которые нужно вырезать.")
        return lines.joined(separator: "\n")
    }

    /// Режет фразы на чанки по `size` с перекрытием `overlap`.
    public static func chunks(_ phrases: [Phrase], size: Int = 40, overlap: Int = 8) -> [Chunk] {
        guard !phrases.isEmpty else { return [] }
        let size = max(2, size)
        let overlap = min(max(0, overlap), size - 1)
        var chunks: [Chunk] = []
        var start = 0
        while start < phrases.count {
            let end = min(phrases.count, start + size)
            let overlapIDs = start == 0 ? [] : Set(phrases[start..<min(end, start + overlap)].map(\.id))
            chunks.append(Chunk(phrases: Array(phrases[start..<end]), overlapIDs: overlapIDs))
            if end == phrases.count { break }
            start = end - overlap
        }
        return chunks
    }

    /// Сводит решения по чанкам в одно, без повторов.
    ///
    /// Фразу из зоны перекрытия видят оба чанка. Следующий чанк видит более поздние дубли, поэтому его
    /// "retake" принимаем всегда. А вот левого контекста у него нет, поэтому "false_start" и "garbage"
    /// из зоны перекрытия принимаем, только если с ними согласен предыдущий чанк.
    public static func mergeResults(_ results: [(chunk: Chunk, removals: [Removal])]) -> [Removal] {
        var merged: [Int: Removal.Reason] = [:]
        for (chunk, removals) in results {
            for removal in removals {
                if chunk.overlapIDs.contains(removal.id), removal.reason != .retake, merged[removal.id] == nil {
                    continue
                }
                // Причину первого чанка сохраняем, кроме случая, когда второй увидел дубль.
                if merged[removal.id] == nil || removal.reason == .retake {
                    merged[removal.id] = removal.reason
                }
            }
        }
        return merged.map { Removal(id: $0.key, reason: $0.value) }.sorted { $0.id < $1.id }
    }
}
