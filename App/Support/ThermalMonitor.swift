import Foundation
import Observation

/// Следит за нагревом устройства.
@MainActor
@Observable
final class ThermalMonitor {
    private(set) var state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            Task { @MainActor in self?.state = state }
        }
    }

    var isHot: Bool { state == .serious || state == .critical }

    var warning: String? {
        switch state {
        case .serious:
            "Айфон сильно нагрелся. Обработка пойдёт медленнее. Сними чехол и убери его с зарядки."
        case .critical:
            "Айфон перегрелся. Лучше отменить обработку и дать ему остыть."
        default:
            nil
        }
    }
}
