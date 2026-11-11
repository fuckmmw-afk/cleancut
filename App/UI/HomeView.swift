import SwiftUI
import UniformTypeIdentifiers

enum Route: Hashable {
    case processing(UUID)
    case review(UUID)
}

struct HomeView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var path: [Route] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showSettings = false
    @State private var isImporting = false
    @State private var error: AppError?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("CleanCut")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Настройки")
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .processing(let id):
                        ProcessingView(projectID: id) { path = [.review(id)] }
                    case .review(let id):
                        ReviewView(projectID: id)
                    }
                }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoVideoPicker(
                onStart: {
                    showPhotoPicker = false
                    isImporting = true
                },
                onFinish: { result in
                    showPhotoPicker = false
                    switch result {
                    case .success(let url): startImport(.staged(url))
                    case .failure(let failure):
                        isImporting = false
                        error = AppError.wrap(failure, title: "Видео не загрузилось")
                    case nil:
                        isImporting = false
                    }
                }
            )
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.movie, .video]) { result in
            switch result {
            case .success(let url): startImport(.external(url))
            case .failure(let failure): error = AppError.wrap(failure, title: "Файл не открылся")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .overlay {
            if isImporting {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text("Копирую видео…").font(.headline)
                        Text("Большие файлы копируются до минуты").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
            }
        }
        .errorAlert($error)
    }

    @ViewBuilder
    private var content: some View {
        List {
            Section {
                Menu {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("Из Фото", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Из Файлов", systemImage: "folder")
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 34))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Выбрать видео").font(.headline)
                            Text("Уберу паузы и неудачные дубли. Всё на устройстве, без интернета.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .disabled(isImporting)
            }

            if !store.projects.isEmpty {
                Section("Проекты") {
                    ForEach(store.projects) { project in
                        Button {
                            open(project)
                        } label: {
                            ProjectRow(project: project)
                        }
                        .tint(.primary)
                    }
                    .onDelete { offsets in
                        for index in offsets { store.delete(store.projects[index]) }
                    }
                }
            }
        }
    }

    private func open(_ project: Project) {
        path = [project.stage == .analyzed ? .review(project.id) : .processing(project.id)]
    }

    private func startImport(_ source: VideoImporter.Source) {
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let project = try await VideoImporter.importVideo(source)
                store.save(project)
                path = [.processing(project.id)]
            } catch {
                self.error = AppError.wrap(error, title: "Не получилось импортировать")
            }
        }
    }
}

private struct ProjectRow: View {
    let project: Project

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.title).font(.body.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: project.stage == .analyzed ? "scissors" : "hourglass")
                .foregroundStyle(project.stage == .analyzed ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let size = Format.bytes(project.fileSize)
        switch project.stage {
        case .analyzed:
            return "\(Format.duration(project.duration)) → \(Format.duration(project.outputDuration)) · \(size)"
        case .transcribed:
            return "\(Format.duration(project.duration)) · \(size) · осталось найти дубли"
        case .imported:
            return "\(Format.duration(project.duration)) · \(size) · не обработано"
        }
    }
}

extension View {
    /// Показывает ошибку человеческим текстом.
    func errorAlert(_ error: Binding<AppError?>) -> some View {
        alert(
            error.wrappedValue?.title ?? "", isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } })
        ) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(error.wrappedValue?.message ?? "")
        }
    }
}
