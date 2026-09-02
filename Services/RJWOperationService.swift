import CryptoKit
import Foundation

enum RJWOperation: Sendable {
    case install(RJWProvider)
    case delete(String)

    var name: String {
        switch self {
        case .install(let provider): return provider.name
        case .delete(let name): return name
        }
    }
}

enum RJWOperationError: LocalizedError {
    case invalidName(String)
    case unsupportedProvider(String)
    case invalidURL(String)
    case missingSubdirectory(String)
    case completedWithFailures(Int)
    case invalidCurrentIndex

    var errorDescription: String? {
        switch self {
        case .invalidName(let name): return "Invalid mod directory name: \(name)"
        case .unsupportedProvider(let type): return "Unsupported provider type: \(type)"
        case .invalidURL(let value): return "Invalid provider URL: \(value)"
        case .missingSubdirectory(let value): return "Archive subdirectory is missing: \(value)"
        case .completedWithFailures(let count): return "Completed with \(count) failed operation(s)."
        case .invalidCurrentIndex: return "Invalid operation index."
        }
    }
}

protocol RJWOperationServiceProtocol: AnyObject {
    var isRunning: Bool { get }

    func updates(operations: [RJWOperation], modsURL: URL) -> AsyncThrowingStream<OperationProgress, Error>
    func cancel()
}

final class RJWOperationService: RJWOperationServiceProtocol, @unchecked Sendable {
    private let commands = CommandExecutor()
    private var task: Task<Void, Never>?
    private var taskID: UUID?

    var isRunning: Bool { task != nil }

    func updates(operations: [RJWOperation], modsURL: URL) -> AsyncThrowingStream<OperationProgress, Error> {
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
                    try await self.run(operations: operations, modsURL: modsURL) { update in
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

    private func run(
        operations: [RJWOperation],
        modsURL: URL,
        progress: @escaping @Sendable (OperationProgress) async -> Void
    ) async throws {
        guard FileManager.default.fileExists(atPath: modsURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        await progress(.init(percent: 2, status: "Подготовка обновления модов (0 из \(operations.count))", output: nil))
        var unchanged = 0
        var failures = 0
        for (index, operation) in operations.enumerated() {
            try Task.checkCancellation()
            let name = operation.name
            do {
                switch operation {
                case .delete:
                    try validate(name: name)
                    let target = modsURL.appendingPathComponent(name, isDirectory: true)
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
                    await progress(.init(percent: 0, status: "", output: "Удаление: \(name)"))
                case .install(let provider):
                    try validate(name: name)
                    let changed = try await install(provider, in: modsURL, current: index + 1, total: operations.count, progress: progress)
                    if !changed { unchanged += 1 }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                await progress(.init(percent: 0, status: "Ошибка: \(name)", output: "Ошибка: \(name)\n\(error.localizedDescription)"))
            }
            let percent = 2 + Double(index + 1) * 98 / Double(operations.count)
            await progress(.init(percent: percent, status: "Обновление модов: \(name) (\(index + 1) из \(operations.count))", output: nil))
        }
        if failures > 0 {
            await progress(.init(percent: 100, status: "Обновление модов завершено с ошибками", output: "Итог: ошибок \(failures), без изменений \(unchanged)"))
            throw RJWOperationError.completedWithFailures(failures)
        }
        await progress(.init(percent: 100, status: "Обновление модов завершено", output: "Итог: без изменений \(unchanged)"))
    }

    private func install(
        _ provider: RJWProvider,
        in modsURL: URL,
        current: Int,
        total: Int,
        progress: @escaping @Sendable (OperationProgress) async -> Void
    ) async throws -> Bool {
        guard current > 0, total > 0 else { throw RJWOperationError.invalidCurrentIndex }
        guard let remoteURL = URL(string: provider.url) else { throw RJWOperationError.invalidURL(provider.url) }
        let fileManager = FileManager.default
        let target = modsURL.appendingPathComponent(provider.name, isDirectory: true)
        let temporary = fileManager.temporaryDirectory.appendingPathComponent("rjw-\(UUID().uuidString)", isDirectory: true)
        let staged = temporary.appendingPathComponent("staged", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }

        switch provider.type {
        case "git":
            let normalizedRemote = provider.url.removingGitSuffix
            if fileManager.fileExists(atPath: target.appendingPathComponent(".git").path),
               let currentRemote = try? commands.run("/usr/bin/git", arguments: ["-C", target.path, "remote", "get-url", "origin"])
                    .trimmingCharacters(in: .whitespacesAndNewlines),
               currentRemote.removingGitSuffix == normalizedRemote {
                let revision = provider.branch ?? "HEAD"
                await progress(.init(percent: 0, status: "Проверка Git-мода: \(provider.name) (\(current) из \(total))", output: "Проверка Git-мода: \(provider.name)"))
                _ = try commands.run("/usr/bin/git", arguments: ["-C", target.path, "fetch", "--quiet", "--depth", "1", "origin", revision], environment: ["GIT_TERMINAL_PROMPT": "0"])
                let local = try commands.run("/usr/bin/git", arguments: ["-C", target.path, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
                let fetched = try commands.run("/usr/bin/git", arguments: ["-C", target.path, "rev-parse", "FETCH_HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard local != fetched else {
                    await progress(.init(percent: 0, status: "", output: "Без изменений: \(provider.name)"))
                    return false
                }
                _ = try commands.run("/usr/bin/git", arguments: ["-C", target.path, "reset", "--quiet", "--hard", "FETCH_HEAD"])
                _ = try commands.run("/usr/bin/git", arguments: ["-C", target.path, "clean", "--quiet", "-fdx"])
                await progress(.init(percent: 0, status: "", output: "Обновлён: \(provider.name)"))
                return true
            }
            await progress(.init(percent: 0, status: "Скачивание Git-мода: \(provider.name) (\(current) из \(total))", output: "Скачивание Git-мода: \(provider.name)"))
            var arguments = ["clone", "--quiet", "--depth", "1"]
            if let branch = provider.branch, !branch.isEmpty {
                arguments += ["--branch", branch, "--single-branch"]
            }
            arguments += [remoteURL.absoluteString, staged.path]
            _ = try commands.run("/usr/bin/git", arguments: arguments, environment: ["GIT_TERMINAL_PROMPT": "0"])
        case "zip":
            await progress(.init(percent: 0, status: "Скачивание ZIP-мода: \(provider.name) (\(current) из \(total))", output: "Скачивание ZIP-мода: \(provider.name)"))
            let (data, response) = try await URLSession.shared.data(from: remoteURL)
            guard (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) == true else {
                throw URLError(.badServerResponse)
            }
            let archive = temporary.appendingPathComponent("archive.zip")
            let extracted = temporary.appendingPathComponent("extracted", isDirectory: true)
            try data.write(to: archive, options: .atomic)
            try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
            _ = try commands.run("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extracted.path])
            let source = provider.subdir.map { extracted.appendingPathComponent($0, isDirectory: true) } ?? extracted
            guard fileManager.fileExists(atPath: source.path) else {
                throw RJWOperationError.missingSubdirectory(provider.subdir ?? "")
            }
            try fileManager.copyItem(at: source, to: staged)
            if fileManager.fileExists(atPath: target.path), try checksum(of: target) == checksum(of: staged) {
                await progress(.init(percent: 0, status: "", output: "Без изменений: \(provider.name)"))
                return false
            }
        default:
            throw RJWOperationError.unsupportedProvider(provider.type)
        }

        let backup = modsURL.appendingPathComponent(".rjw-backup-\(UUID().uuidString)", isDirectory: true)
        let hadTarget = fileManager.fileExists(atPath: target.path)
        if hadTarget { try fileManager.moveItem(at: target, to: backup) }
        do {
            try fileManager.moveItem(at: staged, to: target)
            if hadTarget { try? fileManager.removeItem(at: backup) }
        } catch {
            if hadTarget { try? fileManager.moveItem(at: backup, to: target) }
            throw error
        }
        await progress(.init(percent: 0, status: "", output: "Обновлён: \(provider.name)"))
        return true
    }

    private func validate(name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains(".."),
              name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw RJWOperationError.invalidName(name)
        }
    }

    private func checksum(of directory: URL) throws -> String {
        let fileManager = FileManager.default
        let files = (fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
            .filter { !$0.path.contains("/.git/") && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }
        var digest = SHA256()
        for file in files {
            digest.update(data: Data(file.path.replacingOccurrences(of: directory.path, with: "").utf8))
            digest.update(data: try Data(contentsOf: file))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var removingGitSuffix: String { hasSuffix(".git") ? String(dropLast(4)) : self }
}
