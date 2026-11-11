import Foundation

/// Запрос к LLM и нарезка транскрипта на окна с контекстом.
public enum RetakePrompt {

    /// Окно транскрипта: модель видит `phrases` целиком, но решает только по `targetIDs`.
    public struct Window: Sendable, Equatable {
        public var phrases: [Phrase]
        public var targetIDs: Set<Int>

        public var targets: [Phrase] { phrases.filter { targetIDs.contains($0.id) } }
        public var ids: Set<Int> { Set(phrases.map(\.id)) }
    }

    public static let system = """
        Ты опытный монтажёр. Тебе дают расшифровку сырой записи, где человек говорит на камеру. \
        Фразы пронумерованы и идут по порядку, с таймкодами. Пока человек записывает ролик, он оговаривается, \
        останавливается и произносит кусок заново. Твоя задача: найти неудачные попытки, которые зритель видеть не должен.

        Сначала прочитай весь текст и пойми, о чём говорит человек и как идёт мысль. Потом ищи повторы.

        Что вырезать:
        - "retake": человек сказал фразу или её часть, а потом ПОВТОРИЛ то же самое заново (лучше или полнее). \
        Вырезается РАННЯЯ попытка, остаётся ПОСЛЕДНЯЯ. В поле "kept" укажи номер более поздней фразы, которая её заменяет.
        - "false_start": фраза оборвана на полуслове, и следующая попытка начинает ту же мысль заново. \
        В "kept" укажи номер фразы, где мысль начата заново.
        - "garbage": реплика не для зрителя: «так, стоп», «ещё раз», «бля, заново», ругань на дубль, команды себе. \
        В "kept" поставь 0.

        Чего НЕ вырезать:
        - фразы, которые продолжают мысль или добавляют новое, даже если в них есть те же слова;
        - перечисления, вопросы и ответы, сознательные повторы для акцента («это важно, очень важно»);
        - вступление, выводы, призывы подписаться;
        - фразу, у которой нет более поздней замены (кроме "garbage").
        Если сомневаешься, НЕ вырезай. Пропустить дубль не страшно, вырезать нужную фразу плохо.

        Пример.
        1 [00:00.0–00:01.2] Всем привет, сегодня
        2 [00:01.8–00:02.6] Так, стоп, ещё раз.
        3 [00:03.5–00:06.0] Всем привет, сегодня расскажу про монтаж на айфоне.
        4 [00:06.4–00:09.0] Первое, что нужно сделать, это включить
        5 [00:09.9–00:13.1] Первое, что нужно сделать, это включить авиарежим.
        6 [00:13.5–00:16.0] Он нужен, чтобы уведомления не мешали записи.
        7 [00:16.3–00:18.8] Уведомления правда очень мешают.
        Ответ:
        {"remove":[{"id":1,"kept":3,"reason":"false_start"},{"id":2,"kept":0,"reason":"garbage"},{"id":4,"kept":5,"reason":"retake"}]}
        Фразы 6 и 7 продолжают мысль, их не трогаем.

        Отвечай строго одним JSON-объектом без пояснений и без markdown:
        {"remove":[{"id":N,"kept":M,"reason":"retake|false_start|garbage"}]}
        Если вырезать нечего: {"remove":[]}
        """

    public static let retryReminder = """
        Предыдущий ответ не прошёл проверку. Верни ТОЛЬКО JSON вида \
        {"remove":[{"id":N,"kept":M,"reason":"retake|false_start|garbage"}]}, используя только номера фраз из списка. \
        Вырезай только явные повторы, у которых есть более поздняя замена.
        """

    public static func timecode(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let rest = total - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, rest)
    }

    public static func line(_ phrase: Phrase) -> String {
        "\(phrase.id) [\(timecode(phrase.start))–\(timecode(phrase.end))] \(phrase.text)"
    }

    public static func user(for window: Window, isRetry: Bool = false) -> String {
        var lines = ["Расшифровка:"]
        lines.append(contentsOf: window.phrases.map(line))
        lines.append("")
        let targets = window.targets
        if targets.count < window.phrases.count, let first = targets.first, let last = targets.last {
            lines.append(
                "Остальные фразы даны для контекста. Решай только по фразам с номерами от \(first.id) до \(last.id). "
                    + "В \"kept\" можно указывать любую фразу из расшифровки.")
        }
        lines.append(isRetry ? retryReminder : "Верни JSON со списком фраз, которые нужно вырезать.")
        return lines.joined(separator: "\n")
    }

    /// Нарезает транскрипт на окна. Короткий транскрипт идёт целиком одним окном.
    ///
    /// - Parameters:
    ///   - target: сколько фраз в окне решается.
    ///   - before: сколько фраз перед ними показывается для контекста.
    ///   - after: сколько фраз после них показывается: там лежат более поздние версии дублей.
    ///   - wholeLimit: транскрипт не длиннее этого идёт целиком.
    public static func windows(
        _ phrases: [Phrase], target: Int = 50, before: Int = 30, after: Int = 15, wholeLimit: Int = 90
    ) -> [Window] {
        guard !phrases.isEmpty else { return [] }
        if phrases.count <= wholeLimit {
            return [Window(phrases: phrases, targetIDs: Set(phrases.map(\.id)))]
        }
        let target = max(1, target)
        var windows: [Window] = []
        var start = 0
        while start < phrases.count {
            let end = min(phrases.count, start + target)
            let lower = max(0, start - before)
            let upper = min(phrases.count, end + after)
            windows.append(
                Window(phrases: Array(phrases[lower..<upper]), targetIDs: Set(phrases[start..<end].map(\.id))))
            start = end
        }
        return windows
    }

    /// JSON Schema ответа. Номера ограничены перечислением, поэтому модель не может придумать несуществующую фразу.
    public static func jsonSchema(for window: Window) -> String {
        let targets = window.targets.map(\.id).sorted().map(String.init).joined(separator: ",")
        let kept = ([0] + window.phrases.map(\.id)).sorted().map(String.init).joined(separator: ",")
        let limit = max(1, window.targetIDs.count / 2)
        return """
            {"type":"object","properties":{"remove":{"type":"array","maxItems":\(limit),"items":{"type":"object",\
            "properties":{"id":{"enum":[\(targets)]},"kept":{"enum":[\(kept)]},\
            "reason":{"enum":["retake","false_start","garbage"]}},\
            "required":["id","kept","reason"],"additionalProperties":false}}},\
            "required":["remove"],"additionalProperties":false}
            """
    }

    /// Сводит решения по окнам: в каждом окне учитываются только его целевые фразы.
    public static func mergeResults(_ results: [(window: Window, removals: [Removal])]) -> [Removal] {
        var merged: [Int: Removal] = [:]
        for (window, removals) in results {
            for removal in removals where window.targetIDs.contains(removal.id) && merged[removal.id] == nil {
                merged[removal.id] = removal
            }
        }
        return merged.values.sorted { $0.id < $1.id }
    }
}
