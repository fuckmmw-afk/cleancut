import Foundation
import Observation

/// Проекты лежат в Documents/Projects/<id>/: исходник и project.json с транскриптом и резами.
@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []

    nonisolated static var root: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Projects", isDirectory: true)
    }

    nonisolated static func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    nonisolated static func sourceURL(for project: Project) -> URL {
        directory(for: project.id).appendingPathComponent(project.sourceFileName)
    }

    nonisolated static func exportURL(for project: Project) -> URL {
        directory(for: project.id).appendingPathComponent("export.mp4")
    }

    init() {
        reload()
    }

    func reload() {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let folders = (try? manager.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        var loaded: [Project] = []
        for folder in folders {
            let file = folder.appendingPathComponent("project.json")
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.readToEnd(), let project = try? decoder.decode(Project.self, from: data)
            else { continue }
            // Проект без исходника бесполезен.
            if manager.fileExists(atPath: Self.sourceURL(for: project).path) { loaded.append(project) }
        }
        projects = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func project(_ id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    func save(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.insert(project, at: 0)
        }
        let directory = Self.directory(for: project.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(project) else { return }
        try? data.write(to: directory.appendingPathComponent("project.json"), options: .atomic)
    }

    func delete(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        try? FileManager.default.removeItem(at: Self.directory(for: project.id))
    }
}
