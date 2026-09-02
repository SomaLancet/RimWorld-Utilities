import Foundation
import SwiftUI

#if DEBUG
@MainActor
enum PreviewApplicationModelFactory {
    static func make() -> ApplicationModel {
        let model = ApplicationModel(
            settingsStore: PreviewSettingsStore(),
            pathDetectionService: PreviewPathDetectionService(),
            updateService: PreviewUpdateService(),
            translationService: PreviewTranslationUpdateService(),
            rjwOperationService: PreviewRJWOperationService(),
            rjwCatalogService: PreviewRJWCatalogService()
        )
        model.language = .english
        model.settingsState.modURLs = [URL(fileURLWithPath: "/Applications/RimWorld/RimWorldMac.app/Mods", isDirectory: true)]
        model.translationComponents = "Core, Royalty, Ideology, Biotech, Anomaly"
        model.translationStatus = "Ready to update"
        model.translationStatusKind = .ready
        model.rjwProviders = [
            ("Core", RJWProvider(
                type: "git",
                name: "rjw",
                displayName: "RJW",
                description: "Core mod package.",
                infoURL: nil,
                url: "https://example.com/rjw.git",
                branch: "main",
                subdir: nil,
                disabled: false,
                rimworldVersions: ["1.6"]
            )),
            ("Add-ons", RJWProvider(
                type: "zip",
                name: "rjw-addon",
                displayName: "RJW Add-on",
                description: "Optional add-on package.",
                infoURL: nil,
                url: "https://example.com/rjw-addon.zip",
                branch: nil,
                subdir: nil,
                disabled: false,
                rimworldVersions: ["1.5"]
            ))
        ]
        model.rjwCatalogMessage = ""
        model.rjwStatus = "Ready"
        model.rjwStatusKind = .ready
        model.diagnosticsSummary = """
        Save: Colony.rws
        Game version: 1.5.4104
        Mods in save: 128
        Installed mods: 126
        Missing mods: 2
        Player.log issues: 3
        """
        model.diagnosticCategories = [
            DiagnosticProblemGroup(title: "Mod problems", problems: [
                DiagnosticProblemRow(category: "Mod problems", title: "Example.RequiredMod", subtitle: "Mod not found", details: "Mod: Example.RequiredMod")
            ]),
            DiagnosticProblemGroup(title: "Player.log errors", problems: [
                DiagnosticProblemRow(category: "Player.log errors", title: "XML error", subtitle: "Could not resolve cross-reference", details: "Could not resolve cross-reference in ThingDef.")
            ])
        ]
        return model
    }
}

final class PreviewSettingsStore: SettingsStoreProtocol {
    func load() -> AppSettings? {
        nil
    }

    func save(_ settings: AppSettings) throws {}
}

final class PreviewPathDetectionService: PathDetectionServiceProtocol {
    let rimWorldDataDirectories: [URL] = [
        URL(fileURLWithPath: "/Users/preview/Library/Application Support/RimWorld", isDirectory: true)
    ]
    let preferredDataDirectory = URL(fileURLWithPath: "/Users/preview/Library/Application Support/RimWorld", isDirectory: true)

    func detectedWorkshopModDirectories() -> [URL] {
        [URL(fileURLWithPath: "/Users/preview/Library/Application Support/Steam/steamapps/workshop/content/294100", isDirectory: true)]
    }

    func detectedLocalModDirectories() -> [URL] {
        [URL(fileURLWithPath: "/Applications/RimWorld/RimWorldMac.app/Mods", isDirectory: true)]
    }

    func detectedModDirectories() -> [URL] {
        detectedLocalModDirectories() + detectedWorkshopModDirectories()
    }

    func latestSave() -> URL? {
        URL(fileURLWithPath: "/Users/preview/Library/Application Support/RimWorld/Saves/Colony.rws")
    }

    func detectedConfig() -> URL? {
        URL(fileURLWithPath: "/Users/preview/Library/Application Support/RimWorld/Config/ModsConfig.xml")
    }

    func detectedLog() -> URL? {
        URL(fileURLWithPath: "/Users/preview/Library/Logs/Unity/Player.log")
    }
}

final class PreviewUpdateService: UpdateServiceProtocol {
    func latestRelease(currentVersion: String) async throws -> GitHubRelease? {
        nil
    }
}

final class PreviewTranslationUpdateService: TranslationUpdateServiceProtocol {
    let isRunning = false

    func updates(gameURL: URL) -> AsyncThrowingStream<OperationProgress, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func cancel() {}
}

final class PreviewRJWOperationService: RJWOperationServiceProtocol {
    let isRunning = false

    func updates(operations: [RJWOperation], modsURL: URL) -> AsyncThrowingStream<OperationProgress, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func cancel() {}
}

final class PreviewRJWCatalogService: RJWCatalogServiceProtocol {
    func load() async throws -> [RJWCatalogItem] {
        []
    }
}

#Preview("Welcome") {
    WelcomeSwiftUIView(model: PreviewApplicationModelFactory.make())
        .frame(width: 900, height: 620)
}

#Preview("Settings") {
    SettingsSwiftUIView(model: PreviewApplicationModelFactory.make())
        .frame(width: 900, height: 620)
}

#Preview("Translation") {
    TranslationSwiftUIView(model: PreviewApplicationModelFactory.make())
        .frame(width: 900, height: 620)
}

#Preview("RJW") {
    RJWSwiftUIView(model: PreviewApplicationModelFactory.make())
        .frame(width: 900, height: 620)
}

#Preview("Diagnostics") {
    DiagnosticsSwiftUIView(model: PreviewApplicationModelFactory.make())
        .frame(width: 900, height: 620)
}

#Preview("Mods Manager") {
    let model = PreviewApplicationModelFactory.make()
    PlaceholderPage(
        title: model.title(for: .modsManager),
        description: model.localized("Управление обычными модами RimWorld.", "Manage regular RimWorld mods."),
        message: model.localized("Раздел менеджера модов находится в разработке.", "The Mods Manager section is under development.")
    )
    .frame(width: 900, height: 620)
}

#Preview("About") {
    AboutSwiftUIView(model: PreviewApplicationModelFactory.make())
        .frame(width: 900, height: 620)
}
#endif
