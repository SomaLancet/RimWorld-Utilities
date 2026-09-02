import AppKit
import Foundation
import UniformTypeIdentifiers

struct DiagnosticProblemRow {
    let category: String?
    let title: String
    let subtitle: String
    let details: String

    var isCategory: Bool { category != nil }
}

@MainActor
extension AppDelegate {
    var applicationVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        return appLanguage.resolved == .english ? "Version \(version)" : "Версия \(version)"
    }

    var sidebarVersion: String { applicationVersion }
    var hasConfiguredPaths: Bool {
        appModel.hasConfiguredPaths
    }

    @objc func analyze() {
        appModel.selectedPage = .diagnostics
        appModel.runDiagnostics()
    }
    @objc func updateTranslation() {
        appModel.selectedPage = .translation
        appModel.updateTranslation()
    }
    @objc func applyRJWSelection() {
        appModel.selectedPage = .rjw
        appModel.applyRJWSelection()
    }
    @objc func checkForUpdates() { appModel.checkForUpdates() }
    @objc func openDiagnostics() { appModel.selectedPage = .diagnostics }
    @objc func openSettings() { appModel.selectedPage = .settings }
    @objc func openAbout() { appModel.selectedPage = .about }
    @objc func openTranslation() { appModel.selectedPage = .translation }
    @objc func openRJW() { appModel.selectedPage = .rjw }
    @objc func openModRemoval() { appModel.selectedPage = .modRemoval }
    @objc func openApplicationRepository() { appModel.openApplicationRepository() }
    @objc func openProvidersRepository() { appModel.openProvidersRepository() }
    @objc func openTranslationRepository() { appModel.openTranslationRepository() }
    @objc func toggleSidebar() { appModel.toggleSidebar() }

    @objc func closeSettings() { appModel.selectedPage = .welcome }
    @objc func chooseSave() { appModel.choosePath(.save) }
    @objc func chooseLocalModsDirectory() { appModel.choosePath(.localMods) }
    @objc func chooseWorkshopModsDirectory() { appModel.choosePath(.workshopMods) }
    @objc func chooseConfig() { appModel.choosePath(.config) }
    @objc func chooseLog() { appModel.choosePath(.log) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(analyze) {
            return appModel.settingsState.saveURL != nil && !appModel.diagnosticsRunning
        }
        if menuItem.action == #selector(updateTranslation) {
            return appModel.translationRunning || appModel.rimWorldApplication() != nil
        }
        if menuItem.action == #selector(applyRJWSelection) {
            return appModel.rjwRunning || (appModel.rjwModsDirectory() != nil && !appModel.rjwProviders.isEmpty)
        }
        if menuItem.action == #selector(checkForUpdates) {
            return !appModel.isCheckingUpdates
        }
        return true
    }
}

final class DiagnosticCategoryItem: NSObject {
    let title: String
    let problems: [DiagnosticProblemItem]

    init(title: String, problems: [DiagnosticProblemItem]) {
        self.title = title
        self.problems = problems
    }
}

final class DiagnosticProblemItem: NSObject {
    let row: DiagnosticProblemRow

    init(row: DiagnosticProblemRow) {
        self.row = row
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static let toggleSidebarToolbarItem = NSToolbarItem.Identifier("ToggleSidebar")
    let settingsStore: any SettingsStoreProtocol
    let pathDetectionService: any PathDetectionServiceProtocol
    let updateService: any UpdateServiceProtocol
    lazy var mainWindowController = MainWindowController(owner: self)
    lazy var appMenu = AppMenu(owner: self)
    lazy var appModel = ApplicationModel(
        settingsStore: settingsStore,
        pathDetectionService: pathDetectionService,
        updateService: updateService
    )
    var appLanguage: AppLanguage = .system

    init(
        settingsStore: any SettingsStoreProtocol = SettingsStore(),
        pathDetectionService: any PathDetectionServiceProtocol = PathDetectionService(),
        updateService: any UpdateServiceProtocol = UpdateService()
    ) {
        self.settingsStore = settingsStore
        self.pathDetectionService = pathDetectionService
        self.updateService = updateService
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isUITesting = CommandLine.arguments.contains("--ui-testing")
        appModel.load(isUITesting: isUITesting)
        appLanguage = appModel.language
        appMenu.build()
        mainWindowController.build()
        if CommandLine.arguments.contains("--navigation-smoke-test") {
            exit(0)
        }
        mainWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindowController.window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard appModel.translationRunning || appModel.rjwRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localized("Обновление ещё выполняется", "An update is still running")
        alert.informativeText = localized(
            "При выходе текущая загрузка будет отменена.",
            "Quitting will cancel the current download."
        )
        alert.addButton(withTitle: localized("Отменить обновление и выйти", "Cancel update and quit"))
        alert.addButton(withTitle: localized("Остаться", "Stay"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        appModel.cancelRunningOperations()
        return .terminateNow
    }

    func updateNavigationAvailability() {
        appModel.objectWillChange.send()
    }

    func localized(_ russian: String, _ english: String) -> String {
        appModel.localized(russian, english)
    }

    func title(for page: UtilityPage) -> String {
        appModel.title(for: page)
    }

    func localizedToolText(_ text: String) -> String {
        appModel.localizedToolText(text)
    }

}
