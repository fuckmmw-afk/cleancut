import CutCore
import Foundation
import Observation

enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_626MB"
    case small = "openai_whisper-small"
    case base = "openai_whisper-base"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .largeV3Turbo: "large-v3-turbo"
        case .small: "small"
        case .base: "base"
        }
    }

    var detail: String {
        switch self {
        case .largeV3Turbo: "≈ 630 МБ, лучшее качество"
        case .small: "≈ 490 МБ, быстрее и проще"
        case .base: "≈ 150 МБ, самая лёгкая"
        }
    }
}

enum RetakeModel: String, CaseIterable, Identifiable, Sendable {
    case qwen4B = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    case qwen1_7B = "mlx-community/Qwen3-1.7B-4bit"
    case heuristic = "heuristic"
    case off = "off"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .qwen4B: "Qwen3-4B Instruct (4 бит)"
        case .qwen1_7B: "Qwen3-1.7B (4 бит)"
        case .heuristic: "Без LLM (простые правила)"
        case .off: "Не искать дубли"
        }
    }

    var detail: String {
        switch self {
        case .qwen4B: "≈ 2.3 ГБ, лучшее качество"
        case .qwen1_7B: "≈ 1 ГБ, запасная, если мало памяти"
        case .heuristic: "Ничего не скачивает, ловит только явные повторы"
        case .off: "Вырезаются только паузы"
        }
    }

    var isLLM: Bool { self == .qwen4B || self == .qwen1_7B }
}

/// Снимок настроек, который можно передать в фоновую работу.
struct PipelineSettings: Sendable, Equatable {
    var minPause: Double
    var padding: Double
    var whisperModel: WhisperModel
    var retakeModel: RetakeModel
    var useSilero: Bool

    var plannerOptions: CutPlanner.Options {
        CutPlanner.Options(minPause: minPause, padding: padding)
    }
}

@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var minPause: Double { didSet { defaults.set(minPause, forKey: "minPause") } }
    var paddingMs: Double { didSet { defaults.set(paddingMs, forKey: "paddingMs") } }
    var whisperModel: WhisperModel { didSet { defaults.set(whisperModel.rawValue, forKey: "whisperModel") } }
    var retakeModel: RetakeModel { didSet { defaults.set(retakeModel.rawValue, forKey: "retakeModel") } }
    var useSilero: Bool { didSet { defaults.set(useSilero, forKey: "useSilero") } }
    /// Мбит/с для исходников до 40 кадров/с и выше.
    var bitrate30: Double { didSet { defaults.set(bitrate30, forKey: "bitrate30") } }
    var bitrate60: Double { didSet { defaults.set(bitrate60, forKey: "bitrate60") } }

    init() {
        minPause = defaults.object(forKey: "minPause") as? Double ?? 0.5
        paddingMs = defaults.object(forKey: "paddingMs") as? Double ?? 120
        whisperModel = WhisperModel(rawValue: defaults.string(forKey: "whisperModel") ?? "") ?? .largeV3Turbo
        retakeModel = RetakeModel(rawValue: defaults.string(forKey: "retakeModel") ?? "") ?? .qwen4B
        useSilero = defaults.object(forKey: "useSilero") as? Bool ?? true
        bitrate30 = defaults.object(forKey: "bitrate30") as? Double ?? 10
        bitrate60 = defaults.object(forKey: "bitrate60") as? Double ?? 16
    }

    var pipeline: PipelineSettings {
        PipelineSettings(
            minPause: minPause, padding: paddingMs / 1000, whisperModel: whisperModel,
            retakeModel: retakeModel, useSilero: useSilero)
    }

    var plannerOptions: CutPlanner.Options { pipeline.plannerOptions }

    /// Битрейт экспорта в бит/с для исходника с данной частотой кадров.
    func bitrate(forFPS fps: Double) -> Int {
        Int((fps > 40 ? bitrate60 : bitrate30) * 1_000_000)
    }
}
