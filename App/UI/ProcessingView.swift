import SwiftUI

struct ProcessingView: View {
    let projectID: UUID
    var onFinished: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(ThermalMonitor.self) private var thermal
    @Environment(ModelManager.self) private var models
    @Environment(\.dismiss) private var dismiss

    @State private var model = AnalysisModel()
    @State private var showSettings = false

    private var missingModels: [ModelKind] {
        guard let project = store.project(projectID) else { return [] }
        let needsTranscription = project.stage == .imported || project.words.isEmpty
        return models.missing(for: settings.pipeline, needsTranscription: needsTranscription)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let project = store.project(projectID) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.title).font(.title3.weight(.semibold)).lineLimit(2)
                        Text("\(Format.duration(project.duration)) · \(Format.bytes(project.fileSize))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                if !model.isRunning, model.state != .finished, !missingModels.isEmpty {
                    missingModelsCard
                }

                VStack(spacing: 0) {
                    ForEach(AnalysisModel.Step.allCases, id: \.self) { step in
                        StepRow(step: step, model: model)
                        if step != AnalysisModel.Step.allCases.last { Divider().padding(.leading, 44) }
                    }
                }
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))

                if model.isRunning {
                    Banner(
                        icon: "iphone.radiowaves.left.and.right", tint: .orange,
                        text: keepOpenText)
                }
                if let warning = thermal.warning, model.isRunning {
                    Banner(icon: "thermometer.high", tint: .red, text: warning)
                }

                statusBlock
            }
            .padding()
        }
        .navigationTitle("Анализ")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.isRunning)
        .task {
            if model.state == .idle, missingModels.isEmpty { start() }
        }
        .onChange(of: missingModels.isEmpty) { _, ready in
            if ready, model.state == .idle { start() }
        }
        .onChange(of: model.state) { _, state in
            if state == .finished { onFinished() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onDisappear { model.cancel() }
    }

    private var keepOpenText: String {
        if #available(iOS 26.0, *) {
            return "Лучше не сворачивай приложение и не блокируй экран. Поиск дублей работает только пока приложение открыто."
        } else {
            return "Не сворачивай приложение и не блокируй экран до конца обработки, иначе система её остановит."
        }
    }

    private var missingModelsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Сначала скачай модели", systemImage: "arrow.down.circle")
                .font(.headline)
            Text("Для обработки с текущими настройками не хватает моделей. Их нужно скачать один раз, дальше всё работает без интернета. Обработка начнётся сама, когда они скачаются.")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(missingModels) { kind in
                ModelRow(kind: kind, inUse: true)
            }
            Button {
                showSettings = true
            } label: {
                Text("Открыть настройки моделей").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var statusBlock: some View {
        switch model.state {
        case .running:
            Button(role: .cancel) {
                model.cancel()
            } label: {
                Text("Отменить").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        case .failed(let title, let message):
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.red)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                Button {
                    start()
                } label: {
                    Text("Попробовать ещё раз").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!missingModels.isEmpty)
                Button {
                    showSettings = true
                } label: {
                    Text("Настройки моделей").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        case .cancelled:
            VStack(alignment: .leading, spacing: 12) {
                Text("Обработка отменена. Уже сделанные этапы сохранены.").font(.subheadline).foregroundStyle(.secondary)
                Button {
                    start()
                } label: {
                    Text("Продолжить").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!missingModels.isEmpty)
            }
        case .idle, .finished:
            EmptyView()
        }
    }

    private func start() {
        guard missingModels.isEmpty else { return }
        model.start(projectID: projectID, store: store, settings: settings.pipeline)
    }
}

private struct StepRow: View {
    let step: AnalysisModel.Step
    let model: AnalysisModel

    private enum Status { case pending, active, done, skipped }

    private var status: Status {
        if model.skippedSteps.contains(step) { return .skipped }
        switch model.state {
        case .idle: return .pending
        case .finished: return .done
        default:
            if step.rawValue < model.step.rawValue { return .done }
            if step == model.step { return model.isRunning ? .active : .pending }
            return .pending
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title)
                    .font(.body.weight(status == .active ? .semibold : .regular))
                    .foregroundStyle(status == .pending ? .secondary : .primary)
                if status == .active {
                    if let fraction = model.fraction {
                        ProgressView(value: min(max(fraction, 0), 1))
                    } else {
                        ProgressView(value: nil as Double?).progressViewStyle(.linear)
                    }
                    if !model.detail.isEmpty {
                        Text(model.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                } else if status == .skipped {
                    Text(step == .llm ? "Выключено в настройках" : "Уже сделано").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .active: ProgressView()
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
        case .skipped: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        }
    }
}

struct Banner: View {
    let icon: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
}
