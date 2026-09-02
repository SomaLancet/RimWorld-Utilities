import Foundation

protocol SettingsStoreProtocol: AnyObject {
    func load() -> AppSettings?
    func save(_ settings: AppSettings) throws
}

final class SettingsStore: SettingsStoreProtocol {
    private let fileManager: FileManager
    private let settingsURL: URL?
    private let legacySettingsURL: URL?

    init(fileManager: FileManager = .default, bundle: Bundle = .main) {
        self.fileManager = fileManager
        settingsURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RimWorld Utilities", isDirectory: true)
            .appendingPathComponent("settings.json")
        legacySettingsURL = bundle.resourceURL?.appendingPathComponent("settings.json")
    }

    func load() -> AppSettings? {
        let sourceURL: URL?
        if let settingsURL, fileManager.fileExists(atPath: settingsURL.path) {
            sourceURL = settingsURL
        } else if let legacySettingsURL, fileManager.fileExists(atPath: legacySettingsURL.path) {
            sourceURL = legacySettingsURL
        } else {
            sourceURL = nil
        }

        guard let sourceURL,
              let data = try? Data(contentsOf: sourceURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return nil
        }
        if sourceURL == legacySettingsURL {
            try? save(settings)
        }
        return settings
    }

    func save(_ settings: AppSettings) throws {
        guard let settingsURL else { return }
        try fileManager.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic)
    }
}
