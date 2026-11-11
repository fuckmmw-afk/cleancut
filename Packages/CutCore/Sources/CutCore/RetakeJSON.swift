import Foundation

/// Разбор и проверка ответа LLM вида `{"remove":[{"id":N,"reason":"retake|false_start|garbage"}]}`.
public enum RetakeJSON {

    public enum ParseError: Error, Equatable, Sendable {
        case noJSONObject
        case invalidJSON
        case missingRemoveArray
        case invalidItem
        /// Модель сослалась на фразу, которой не было в запросе.
        case unknownID(Int)
        /// Модель предлагает вырезать подозрительно большую долю фраз.
        case tooManyRemovals(Int, of: Int)
    }

    /// - Parameters:
    ///   - allowedIDs: id фраз, которые были в запросе.
    ///   - maxRemovalShare: если модель хочет вырезать больше этой доли фраз, ответ считается браком.
    public static func parse(
        _ response: String, allowedIDs: Set<Int>, maxRemovalShare: Double = 0.7
    ) throws -> [Removal] {
        let cleaned = stripNoise(response)
        guard let jsonText = firstJSONObject(in: cleaned) else { throw ParseError.noJSONObject }
        guard let data = jsonText.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else { throw ParseError.invalidJSON }
        guard let items = root["remove"] as? [Any] else { throw ParseError.missingRemoveArray }

        var removals: [Removal] = []
        var seen = Set<Int>()
        for item in items {
            guard let dict = item as? [String: Any], let id = intValue(dict["id"]) else {
                throw ParseError.invalidItem
            }
            guard let reasonText = dict["reason"] as? String, let reason = reason(from: reasonText) else {
                throw ParseError.invalidItem
            }
            guard allowedIDs.contains(id) else { throw ParseError.unknownID(id) }
            // 0 или отсутствие поля значит «замены нет».
            let kept = intValue(dict["kept"]).flatMap { $0 > 0 ? $0 : nil }
            if seen.insert(id).inserted {
                removals.append(Removal(id: id, reason: reason, kept: kept))
            }
        }

        if allowedIDs.count >= 4, Double(removals.count) > Double(allowedIDs.count) * maxRemovalShare {
            throw ParseError.tooManyRemovals(removals.count, of: allowedIDs.count)
        }
        return removals.sorted { $0.id < $1.id }
    }

    // MARK: - Внутреннее

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            // Отсекаем true/false и дробные значения.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let double = number.doubleValue
            return double == double.rounded() ? number.intValue : nil
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    private static func reason(from text: String) -> Removal.Reason? {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "retake", "repeat", "duplicate": return .retake
        case "false_start", "falsestart": return .falseStart
        case "garbage", "filler": return .garbage
        default: return nil
        }
    }

    /// Убирает блоки размышлений и обёртку ```json.
    static func stripNoise(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>") {
            if let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
            }
        }
        return result.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
    }

    /// Первый сбалансированный JSON-объект в тексте (с учётом строк и экранирования).
    static func firstJSONObject(in text: String) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var startIndex: String.Index?
        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"":
                if depth > 0 { inString = true }
            case "{":
                if depth == 0 { startIndex = index }
                depth += 1
            case "}":
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let startIndex {
                    return String(text[startIndex...index])
                }
            default:
                break
            }
        }
        return nil
    }
}

#if !canImport(Darwin)
// На Linux у JSONSerialization булевы значения приходят как NSNumber без CFBoolean.
private func CFGetTypeID(_ number: NSNumber) -> Int {
    let type = String(cString: number.objCType)
    return type == "c" || type == "B" ? 1 : 0
}
private func CFBooleanGetTypeID() -> Int { 1 }
#endif
