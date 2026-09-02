import Foundation

enum CommandExecutorError: LocalizedError {
    case failed(command: String, status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .failed(let command, let status, let output):
            return "\(command) exited with status \(status): \(output)"
        }
    }
}

final class CommandExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func run(_ executable: String, arguments: [String], environment: [String: String] = [:]) throws -> String {
        try Task.checkCancellation()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        lock.lock()
        self.process = process
        lock.unlock()
        defer {
            lock.lock()
            if self.process === process {
                self.process = nil
            }
            lock.unlock()
        }
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            throw CommandExecutorError.failed(
                command: ([executable] + arguments).joined(separator: " "),
                status: process.terminationStatus,
                output: output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output
    }

    func cancel() {
        lock.lock()
        let process = self.process
        lock.unlock()
        process?.terminate()
    }
}
