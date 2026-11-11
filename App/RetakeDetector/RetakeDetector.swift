import CutCore
import Foundation

enum RetakePhase: Sendable {
    case downloading(Double)
    case loading
    case analyzing(Double)
}

struct RetakeOutcome: Sendable {
    struct Rejection: Sendable {
        var removal: Removal
        var why: String
    }

    /// Решения, которые прошли проверку: эти фразы вырезаются.
    var removals: [Removal]
    /// Предложения модели, которые проверку не прошли: они показываются на ревью, но не вырезаются.
    var rejected: [Rejection] = []
    /// Замечания для пользователя: что пошло не так и чем это заменили.
    var notes: [String] = []
}

/// Ищет в транскрипте дубли, фальстарты и мусор. За протоколом, чтобы модель можно было сменить.
protocol RetakeDetector: Sendable {
    func detect(
        phrases: [Phrase], log: AnalysisLog, onPhase: @escaping @Sendable (RetakePhase) -> Void
    ) async throws -> RetakeOutcome
}

/// Правила без LLM: ничего не скачивает и не грузит.
struct HeuristicRetakeDetector: RetakeDetector {
    func detect(
        phrases: [Phrase], log: AnalysisLog, onPhase: @escaping @Sendable (RetakePhase) -> Void
    ) async throws -> RetakeOutcome {
        onPhase(.analyzing(1))
        let removals = HeuristicRetake.detect(phrases)
        log.write("Правила без LLM: найдено \(removals.count)")
        return RetakeOutcome(removals: removals)
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
