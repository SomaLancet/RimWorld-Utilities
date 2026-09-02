import Foundation

struct OperationProgress: Sendable {
    let percent: Double
    let status: String
    let output: String?
}

enum TranslationUpdateError: LocalizedError {
    case invalidGameDirectory
    case invalidArchive(String)
    case missingComponent(String)

    var errorDescription: String? {
        switch self {
        case .invalidGameDirectory: return "RimWorld Languages directory is unavailable or not writable."
        case .invalidArchive(let reason): return "Invalid translation archive: \(reason)"
        case .missingComponent(let component): return "The archive does not contain translation data for \(component)."
        }
    }
}

protocol TranslationUpdateServiceProtocol: AnyObject {
    var isRunning: Bool { get }

    func updates(gameURL: URL) -> AsyncThrowingStream<OperationProgress, Error>
    func cancel()
}

final class TranslationUpdateService: TranslationUpdateServiceProtocol, @unchecked Sendable {
    private let commands = CommandExecutor()
    private var task: Task<Void, Never>?
    private var taskID: UUID?

    var isRunning: Bool { task != nil }

    func updates(gameURL: URL) -> AsyncThrowingStream<OperationProgress, Error> {
        AsyncThrowingStream { continuation in
            guard task == nil else {
                continuation.finish()
                return
            }

            let operationID = UUID()
            taskID = operationID
            task = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    try await self.update(gameURL: gameURL) { update in
                        continuation.yield(update)
                    }
                    self.clearTask(operationID)
                    continuation.finish()
                } catch {
                    self.clearTask(operationID)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }
        }
    }

    func cancel() {
        guard task != nil else { return }
        task?.cancel()
        commands.cancel()
    }

    private func clearTask(_ operationID: UUID) {
        if taskID == operationID {
            task = nil
            taskID = nil
        }
    }

    private func update(gameURL: URL, progress: @escaping @Sendable (OperationProgress) async -> Void) async throws {
        let fileManager = FileManager.default
        let dataURL = gameURL.appendingPathComponent("Data", isDirectory: true)
        let coreLanguages = dataURL.appendingPathComponent("Core/Languages", isDirectory: true)
        guard fileManager.isWritableFile(atPath: coreLanguages.path) else { throw TranslationUpdateError.invalidGameDirectory }

        await progress(.init(percent: 5, status: "Подготовка обновления перевода", output: nil))
        let temporary = fileManager.temporaryDirectory.appendingPathComponent("rimworld-ru-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }

        await progress(.init(percent: 8, status: "Проверка версии перевода", output: nil))
        let commitURL = URL(string: "https://api.github.com/repos/Ludeon/RimWorld-ru/commits/master")!
        let (commitData, commitResponse) = try await URLSession.shared.data(from: commitURL)
        guard (commitResponse as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) == true,
              let revision = (try JSONSerialization.jsonObject(with: commitData) as? [String: Any])?["sha"] as? String,
              revision.count == 40 else {
            throw TranslationUpdateError.invalidArchive("GitHub returned an invalid revision")
        }

        await progress(.init(percent: 10, status: "Скачивание перевода", output: nil))
        let archiveURL = URL(string: "https://github.com/Ludeon/RimWorld-ru/archive/\(revision).tar.gz")!
        let (archiveData, archiveResponse) = try await URLSession.shared.data(from: archiveURL)
        guard (archiveResponse as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) == true, !archiveData.isEmpty else {
            throw TranslationUpdateError.invalidArchive("download failed")
        }
        let archive = temporary.appendingPathComponent("translation.tar.gz")
        try archiveData.write(to: archive, options: .atomic)

        await progress(.init(percent: 35, status: "Проверка архива", output: nil))
        let listing = try commands.run("/usr/bin/tar", arguments: ["-tzf", archive.path])
        let paths = listing.split(whereSeparator: \Character.isNewline).map(String.init)
        guard let root = paths.first?.split(separator: "/").first.map(String.init), !root.isEmpty else {
            throw TranslationUpdateError.invalidArchive("missing root directory")
        }
        guard paths.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") && $0.split(separator: "/").first == Substring(root) }) else {
            throw TranslationUpdateError.invalidArchive("unsafe paths")
        }

        await progress(.init(percent: 45, status: "Распаковка архива", output: nil))
        _ = try commands.run("/usr/bin/tar", arguments: ["-xzf", archive.path, "-C", temporary.path])
        let source = temporary.appendingPathComponent(root, isDirectory: true)
        guard fileManager.fileExists(atPath: source.appendingPathComponent("Core").path) else {
            throw TranslationUpdateError.missingComponent("Core")
        }

        let components = try fileManager.contentsOfDirectory(at: dataURL, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("Languages").path) }
            .map(\.lastPathComponent)
            .sorted()
        guard !components.isEmpty else { throw TranslationUpdateError.invalidGameDirectory }

        await progress(.init(percent: 55, status: "Подготовка установки перевода", output: nil))
        var installed: [(target: URL, backup: URL?)] = []
        do {
            for (index, component) in components.enumerated() {
                try Task.checkCancellation()
                let componentSource = source.appendingPathComponent(component, isDirectory: true)
                guard fileManager.fileExists(atPath: componentSource.path) else { throw TranslationUpdateError.missingComponent(component) }
                let languages = dataURL.appendingPathComponent(component).appendingPathComponent("Languages")
                let target = languages.appendingPathComponent("Russian (Русский)", isDirectory: true)
                let backup = languages.appendingPathComponent(".rimworld-ru-backup-\(UUID().uuidString)", isDirectory: true)
                let hadTarget = fileManager.fileExists(atPath: target.path)
                if hadTarget { try fileManager.moveItem(at: target, to: backup) }
                do {
                    try fileManager.copyItem(at: componentSource, to: target)
                    installed.append((target, hadTarget ? backup : nil))
                } catch {
                    if hadTarget { try? fileManager.moveItem(at: backup, to: target) }
                    throw error
                }
                let percent = 70 + Double(index + 1) * 25 / Double(components.count)
                await progress(.init(percent: percent, status: "Установка перевода: \(component) (\(index + 1) из \(components.count))", output: "Обновлён: \(component)"))
            }
            installed.compactMap(\.backup).forEach { try? fileManager.removeItem(at: $0) }
        } catch {
            for item in installed.reversed() {
                try? fileManager.removeItem(at: item.target)
                if let backup = item.backup { try? fileManager.moveItem(at: backup, to: item.target) }
            }
            throw error
        }
        await progress(.init(percent: 100, status: "Обновление перевода завершено", output: nil))
    }
}
