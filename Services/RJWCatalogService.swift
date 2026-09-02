import Foundation

struct RJWCatalogItem: Sendable {
    let category: String
    let provider: RJWProvider
}

protocol RJWCatalogServiceProtocol: AnyObject, Sendable {
    func load() async throws -> [RJWCatalogItem]
}

enum RJWCatalogError: LocalizedError {
    case invalidTOML(String)

    var errorDescription: String? {
        switch self {
        case .invalidTOML(let details):
            return "Invalid providers.toml: \(details)"
        }
    }
}

final class RJWCatalogService: RJWCatalogServiceProtocol, Sendable {
    private static let packageURL = URL(string: "https://gitgud.io/api/v4/projects/AblativeAbsolute%2Flibidinous_loader_providers/packages/generic/provider_nopin/latest/providers.json")!
    private static let repositoryURL = "https://gitgud.io/AblativeAbsolute/libidinous_loader_providers.git"

    private let session: URLSession
    private let repositoryLoader: @Sendable () throws -> Data

    init(session: URLSession = .shared, commands: CommandExecutor = CommandExecutor()) {
        self.session = session
        repositoryLoader = { try Self.loadRepositoryData(commands: commands) }
    }

    init(session: URLSession, repositoryLoader: @escaping @Sendable () throws -> Data) {
        self.session = session
        self.repositoryLoader = repositoryLoader
    }

    func load() async throws -> [RJWCatalogItem] {
        var request = URLRequest(url: Self.packageURL)
        request.setValue("RimWorld-Utilities", forHTTPHeaderField: "User-Agent")

        if let (data, response) = try? await session.data(for: request),
           let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           let decoded = try? Self.decodeJSON(data) {
            return decoded
        }

        return try await loadFromRepository()
    }

    private func loadFromRepository() async throws -> [RJWCatalogItem] {
        try await Task.detached(priority: .userInitiated) { [repositoryLoader] in
            try Self.decodeTOML(repositoryLoader())
        }.value
    }

    private static func loadRepositoryData(commands: CommandExecutor) throws -> Data {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("rjw-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try commands.run(
            "/usr/bin/git",
            arguments: [
                "clone", "--quiet", "--depth", "1", "--branch", "v1", "--single-branch",
                repositoryURL, temporary.path
            ],
            environment: ["GIT_TERMINAL_PROMPT": "0"]
        )
        return try Data(contentsOf: temporary.appendingPathComponent("providers.toml"))
    }

    static func decodeJSON(_ data: Data) throws -> [RJWCatalogItem] {
        let response = try JSONDecoder().decode(RJWProvidersResponse.self, from: data)
        return sortedItems(response.providers)
    }

    static func decodeTOML(_ data: Data) throws -> [RJWCatalogItem] {
        guard let source = String(data: data, encoding: .utf8) else {
            throw RJWCatalogError.invalidTOML("file is not UTF-8")
        }
        var providers: [String: [String: RJWProvider]] = [:]
        var currentCategory: String?
        var values: [String: String] = [:]

        func finishProvider() throws {
            guard let category = currentCategory else { return }
            guard let type = values["type"],
                  let name = values["name"],
                  let description = values["description"],
                  let url = values["url"] else {
                throw RJWCatalogError.invalidTOML("provider in \(category) is missing a required field")
            }
            let provider = RJWProvider(
                type: type,
                name: name,
                displayName: values["display_name"],
                description: description,
                infoURL: values["info_url"],
                url: url,
                branch: values["branch"],
                subdir: values["subdir"],
                disabled: values["disabled"].flatMap(Bool.init),
                rimworldVersions: values["rimworld_versions"]?.split(separator: ",").map { String($0) }
            )
            providers[category, default: [:]][name] = provider
        }

        for rawLine in source.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[providers."), line.hasSuffix("]") {
                try finishProvider()
                values = [:]
                let section = line.dropFirst("[providers.".count).dropLast()
                guard let separator = section.firstIndex(of: ".") else {
                    throw RJWCatalogError.invalidTOML("invalid provider section \(line)")
                }
                currentCategory = String(section[..<separator])
                continue
            }
            if line.hasPrefix("[") {
                try finishProvider()
                currentCategory = nil
                values = [:]
                continue
            }
            guard currentCategory != nil,
                  !line.isEmpty,
                  !line.hasPrefix("#"),
                  let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard ["type", "name", "display_name", "description", "info_url", "url", "branch", "subdir", "disabled", "rimworld_versions"].contains(key) else {
                continue
            }
            if rawValue == "true" || rawValue == "false" {
                values[key] = rawValue
            } else if let value = try? JSONDecoder().decode([String].self, from: Data(rawValue.utf8)) {
                values[key] = value.joined(separator: ",")
            } else if let value = try? JSONDecoder().decode(String.self, from: Data(rawValue.utf8)) {
                values[key] = value
            } else {
                throw RJWCatalogError.invalidTOML("invalid value for \(key)")
            }
        }
        try finishProvider()
        guard !providers.isEmpty else { throw RJWCatalogError.invalidTOML("no providers found") }
        return sortedItems(providers)
    }

    private static func sortedItems(_ providers: [String: [String: RJWProvider]]) -> [RJWCatalogItem] {
        providers.keys.sorted().flatMap { category in
            (providers[category] ?? [:]).values
                .sorted {
                    ($0.displayName ?? $0.name).localizedCaseInsensitiveCompare($1.displayName ?? $1.name) == .orderedAscending
                }
                .map { RJWCatalogItem(category: category, provider: $0) }
        }
    }
}
