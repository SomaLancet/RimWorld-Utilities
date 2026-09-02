import Foundation

enum UtilityPage: CaseIterable, Equatable {
    case welcome
    case translation
    case rjw
    case modsManager
    case diagnostics
    case modRemoval
    case settings
    case about

    func title(for language: AppLanguage) -> String {
        let english = language.resolved == .english
        switch self {
        case .welcome: return english ? "Welcome" : "Приветствие"
        case .translation: return english ? "Translation" : "Перевод"
        case .rjw: return "RJW"
        case .modsManager: return english ? "Mods Manager" : "Менеджер модов"
        case .diagnostics: return english ? "Scanner" : "Сканер"
        case .modRemoval: return english ? "Mod Remover" : "Удаление мода"
        case .settings: return english ? "Settings" : "Настройки"
        case .about: return english ? "About" : "О приложении"
        }
    }

    var symbolName: String {
        switch self {
        case .welcome: return "house"
        case .translation: return "character.book.closed"
        case .rjw: return "shippingbox"
        case .modsManager: return "square.grid.2x2"
        case .diagnostics: return "magnifyingglass"
        case .modRemoval: return "trash"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

enum AppLanguage: String, Codable, CaseIterable {
    case system
    case russian
    case english

    var resolved: AppLanguage {
        guard self == .system else { return self }
        return Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") == true ? .russian : .english
    }

    var displayName: String {
        switch self {
        case .system: return "Системный / System"
        case .russian: return "Русский"
        case .english: return "English"
        }
    }
}

struct AppSettings: Codable {
    var savePath: String?
    var modPaths: [String] = []
    var configPath: String?
    var logPath: String?
    var language: AppLanguage?
}

enum SettingsPathKind: Int, CaseIterable {
    case save
    case localMods
    case workshopMods
    case config
    case log
}

struct SettingsState {
    var saveDirectoryURL: URL?
    var saveURL: URL?
    var modURLs: [URL] = []
    var configURL: URL?
    var logURL: URL?
    var suggestedSaveDirectoryURL: URL?
    var suggestedSaveURL: URL?
    var suggestedLocalModsURL: URL?
    var suggestedWorkshopModsURL: URL?
    var suggestedConfigURL: URL?
    var suggestedLogURL: URL?
    var preferredLanguage: AppLanguage = .system

    func configuredPath(for kind: SettingsPathKind) -> URL? {
        switch kind {
        case .save:
            return saveDirectoryURL ?? suggestedSaveDirectoryURL ?? suggestedSaveURL?.deletingLastPathComponent()
        case .localMods:
            return modURLs.first { !$0.path.contains("/workshop/content/294100") && $0.lastPathComponent == "Mods" }
                ?? modURLs.first { !$0.path.contains("/workshop/content/294100") }
                ?? suggestedLocalModsURL
        case .workshopMods:
            return modURLs.first { $0.path.contains("/workshop/content/294100") } ?? suggestedWorkshopModsURL
        case .config:
            return configURL ?? suggestedConfigURL
        case .log:
            return logURL ?? suggestedLogURL
        }
    }

    var appSettings: AppSettings {
        AppSettings(
            savePath: saveDirectoryURL?.path,
            modPaths: modURLs.map(\.path),
            configPath: configURL?.path,
            logPath: logURL?.path,
            language: preferredLanguage
        )
    }
}

struct TranslationOperationState {
    var outputBuffer = ""
    var errors: [String] = []
    var updatedComponents: [String] = []
    var cancellationRequested = false

    mutating func resetForRun() {
        outputBuffer = ""
        errors = []
        updatedComponents = []
        cancellationRequested = false
    }

    mutating func consumeBufferedLines(_ text: String) -> [String] {
        outputBuffer += text
        let lines = outputBuffer.components(separatedBy: .newlines)
        outputBuffer = lines.last ?? ""
        return lines.dropLast().filter { !$0.isEmpty }
    }

    mutating func flushBufferedLine() -> String? {
        guard !outputBuffer.isEmpty else { return nil }
        defer { outputBuffer = "" }
        return outputBuffer
    }

    mutating func recordInstalledComponent(from status: String) {
        let prefix = "Установка перевода: "
        guard status.hasPrefix(prefix) else { return }
        let component = String(status.dropFirst(prefix.count)).components(separatedBy: " (").first ?? ""
        if !component.isEmpty {
            updatedComponents.append(component)
        }
    }
}


final class RJWCategoryItem: NSObject {
    let title: String
    let providers: [RJWProviderItem]

    init(title: String, providers: [RJWProviderItem]) {
        self.title = title
        self.providers = providers
    }
}

final class RJWProviderItem: NSObject {
    let category: String
    let provider: RJWProvider

    init(category: String, provider: RJWProvider) {
        self.category = category
        self.provider = provider
    }
}
