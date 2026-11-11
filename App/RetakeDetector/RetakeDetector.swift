import CutCore
import Foundation

enum RetakePhase: Sendable {
    case downloading(Double)
    case loading
    case analyzing(Double)
}

struct RetakeOutcome: Sendable {
    var removals: [Removal]
    /// Замечания для пользователя: что пошло не так и чем это заменили.
    var notes: [String] = []
}

/// Ищет в транскрипте дубли, фальстарты и мусор. За протоколом, чтобы модель можно было сменить.
protocol RetakeDetector: Sendable {
    func detect(
        phrases: [Phrase], onPhase: @escaping @Sendable (RetakePhase) -> Void
    ) async throws -> RetakeOutcome
}

/// Правила без LLM: ничего не скачивает и не грузит.
struct HeuristicRetakeDetector: RetakeDetector {
    func detect(
        phrases: [Phrase], onPhase: @escaping @Sendable (RetakePhase) -> Void
    ) async throws -> RetakeOutcome {
        onPhase(.analyzing(1))
        return RetakeOutcome(removals: HeuristicRetake.detect(phrases))
    }
}

enum RetakeDetectorFactory {
    static func make(_ model: RetakeModel) -> (any RetakeDetector)? {
        switch model {
        case .qwen4B, .qwen1_7B: MLXRetakeDetector(modelID: model.rawValue)
        case .heuristic: HeuristicRetakeDetector()
        case .off: nil
        }
    }
}
