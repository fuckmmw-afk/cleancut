import CutCore
import Foundation

struct Project: Codable, Identifiable, Sendable, Equatable {
    enum Stage: String, Codable, Sendable {
        /// Видео скопировано, анализа ещё не было.
        case imported
        /// Есть речь и транскрипт, дубли ещё не искались.
        case transcribed
        /// Анализ закончен, можно ревьюить и экспортировать.
        case analyzed
    }

    var id = UUID()
    var title: String
    var createdAt = Date()
    var sourceFileName: String
    var fileSize: Int64
    var duration: Double
    var fps: Double
    /// Размер кадра с учётом поворота.
    var width: Int
    var height: Int

    var stage: Stage = .imported
    var words: [Word] = []
    var phrases: [Phrase] = []
    var speech: [TimeRange] = []
    var cuts: [Cut] = []
    /// Замечания по анализу, которые стоит показать на экране ревью.
    var notes: [String] = []
    /// Настройки, с которыми считались паузы.
    var minPause: Double = 0.5
    var padding: Double = 0.12

    var plannerOptions: CutPlanner.Options {
        CutPlanner.Options(minPause: minPause, padding: padding)
    }

    var finalCuts: [TimeRange] {
        CutPlanner.finalCuts(cuts, duration: duration, options: plannerOptions)
    }

    var outputDuration: Double {
        duration - finalCuts.reduce(0) { $0 + $1.duration }
    }
}
