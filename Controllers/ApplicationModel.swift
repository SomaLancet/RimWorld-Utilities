import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

protocol ApplicationSystemActionsProtocol: AnyObject {
    func chooseURL(files: Bool, directories: Bool, types: [String], suggested: URL?, message: String, prompt: String) -> URL?
    func open(_ url: URL)
    func reveal(_ url: URL)
    func playSuccessSound()
    func playFailureSound()
    func presentWarning(title: String, message: String, details: String?)
}

final class ApplicationSystemActions: ApplicationSystemActionsProtocol {
    func chooseURL(files: Bool, directories: Bool, types: [String], suggested: URL?, message: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = files
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = prompt
        if !types.isEmpty {
            panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        }
        if let suggested {
            panel.directoryURL = suggested.hasDirectoryPath ? suggested : suggested.deletingLastPathComponent()
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func playSuccessSound() {
        NSSound(named: "Glass")?.play()
    }

    func playFailureSound() {
        NSSound.beep()
    }

    func presentWarning(title: String, message: String, details: String?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = [message, details].compactMap { $0 }.joined(separator: "\n\n")
        alert.runModal()
    }
}

struct TranslationFeatureState {
    var components = ""
    var status = ""
    var progress = 0.0
    var running = false
    var recentOutput = ""
    var console = ""
    var statusKind: OperationStatusKind = .idle
}

struct RJWFeatureState {
    var providers: [(category: String, provider: RJWProvider)] = []
    var selectedProviderNames: Set<String> = []
    var installedProviderNames: Set<String> = []
    var status = ""
    var progress = 0.0
    var running = false
    var loadingCatalog = false
    var console = ""
    var recentOutput = ""
    var catalogMessage = ""
    var statusKind: OperationStatusKind = .idle
}

struct DiagnosticsFeatureState {
    var running = false
    var status = ""
    var statusKind: OperationStatusKind = .idle
    var summary = ""
    var categories: [DiagnosticProblemGroup] = []
    var selectedDiagnostic: DiagnosticProblemRow?
}

struct SaveCleanerFeatureState {
    var running = false
    var progress = 0.0
    var status = ""
    var statusKind: OperationStatusKind = .idle
    var report: SaveCleanerReport?
}

struct ModRemovalFeatureState {
    var searchText = ""
    var candidates: [ModRemovalCandidate] = []
    var catalogLoading = false
    var catalogStatus = ""
    var modURL: URL?
    var selectedModPaths: Set<String> = []
    var running = false
    var progress = 0.0
    var status = ""
    var statusKind: OperationStatusKind = .idle
    var report: ModRemovalReport?
    var removeMetadata = false
    var selectedStep: ModRemovalWizardStep = .save
}

@MainActor
final class ApplicationModel: ObservableObject {
    let settingsStore: any SettingsStoreProtocol
    let pathDetectionService: any PathDetectionServiceProtocol
    let updateService: any UpdateServiceProtocol
    let translationService: any TranslationUpdateServiceProtocol
    let rjwOperationService: any RJWOperationServiceProtocol
    let rjwCatalogService: any RJWCatalogServiceProtocol
    let rimWorldAnalyzer: any RimWorldAnalyzerProtocol
    let saveCleanerService: any SaveCleanerServiceProtocol
    let modRemovalService: any ModRemovalServiceProtocol
    let systemActions: any ApplicationSystemActionsProtocol

    @Published var selectedPage: UtilityPage = .welcome
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    @Published var language: AppLanguage = .system
    @Published var settingsState = SettingsState()
    @Published var pathLabels: [SettingsPathKind: String] = [:]
    @Published var detectedPathAvailable: Set<SettingsPathKind> = []
    @Published var saveCandidates: [SaveCandidate] = []
    @Published var updateStatus = ""
    @Published var isCheckingUpdates = false
    private var saveSelectionIsUserSelected = false
    private var updateCheckTask: Task<Void, Never>?

    @Published private var translationState = TranslationFeatureState()
    private var translationOperationState = TranslationOperationState()
    private var translationTask: Task<Void, Never>?

    @Published private var rjwState = RJWFeatureState()
    private var rjwOperationState = TranslationOperationState()
    private var rjwCatalogTask: Task<Void, Never>?
    private var rjwTask: Task<Void, Never>?

    @Published private var diagnosticsState = DiagnosticsFeatureState()
    private var diagnosticsTask: Task<Void, Never>?

    @Published private var saveCleanerState = SaveCleanerFeatureState()
    private var saveCleanerTask: Task<Void, Never>?

    @Published private var modRemovalState = ModRemovalFeatureState()
    private var modRemovalCatalogTask: Task<Void, Never>?
    private var modRemovalTask: Task<Void, Never>?

    var resolvedLanguage: AppLanguage { language.resolved }
    var applicationVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        return resolvedLanguage == .english ? "Version \(version)" : "Версия \(version)"
    }
    var hasConfiguredPaths: Bool {
        settingsState.saveDirectoryURL != nil || settingsState.saveURL != nil || !settingsState.modURLs.isEmpty || settingsState.configURL != nil || settingsState.logURL != nil
    }

    var translationComponents: String {
        get { translationState.components }
        set { translationState.components = newValue }
    }
    var translationStatus: String {
        get { translationState.status }
        set { translationState.status = newValue }
    }
    var translationProgress: Double {
        get { translationState.progress }
        set { translationState.progress = newValue }
    }
    var translationRunning: Bool {
        get { translationState.running }
        set { translationState.running = newValue }
    }
    var translationRecentOutput: String {
        get { translationState.recentOutput }
        set { translationState.recentOutput = newValue }
    }
    var translationConsole: String {
        get { translationState.console }
        set { translationState.console = newValue }
    }
    var translationStatusKind: OperationStatusKind {
        get { translationState.statusKind }
        set { translationState.statusKind = newValue }
    }

    var rjwProviders: [(category: String, provider: RJWProvider)] {
        get { rjwState.providers }
        set { rjwState.providers = newValue }
    }
    var selectedRJWProviderNames: Set<String> {
        get { rjwState.selectedProviderNames }
        set { rjwState.selectedProviderNames = newValue }
    }
    var installedRJWProviderNames: Set<String> {
        get { rjwState.installedProviderNames }
        set { rjwState.installedProviderNames = newValue }
    }
    var rjwStatus: String {
        get { rjwState.status }
        set { rjwState.status = newValue }
    }
    var rjwProgress: Double {
        get { rjwState.progress }
        set { rjwState.progress = newValue }
    }
    var rjwRunning: Bool {
        get { rjwState.running }
        set { rjwState.running = newValue }
    }
    var rjwLoadingCatalog: Bool {
        get { rjwState.loadingCatalog }
        set { rjwState.loadingCatalog = newValue }
    }
    var rjwConsole: String {
        get { rjwState.console }
        set { rjwState.console = newValue }
    }
    var rjwRecentOutput: String {
        get { rjwState.recentOutput }
        set { rjwState.recentOutput = newValue }
    }
    var rjwCatalogMessage: String {
        get { rjwState.catalogMessage }
        set { rjwState.catalogMessage = newValue }
    }
    var rjwStatusKind: OperationStatusKind {
        get { rjwState.statusKind }
        set { rjwState.statusKind = newValue }
    }

    var diagnosticsRunning: Bool {
        get { diagnosticsState.running }
        set { diagnosticsState.running = newValue }
    }
    var diagnosticsStatus: String {
        get { diagnosticsState.status }
        set { diagnosticsState.status = newValue }
    }
    var diagnosticsStatusKind: OperationStatusKind {
        get { diagnosticsState.statusKind }
        set { diagnosticsState.statusKind = newValue }
    }
    var diagnosticsSummary: String {
        get { diagnosticsState.summary }
        set { diagnosticsState.summary = newValue }
    }
    var diagnosticCategories: [DiagnosticProblemGroup] {
        get { diagnosticsState.categories }
        set { diagnosticsState.categories = newValue }
    }
    var selectedDiagnostic: DiagnosticProblemRow? {
        get { diagnosticsState.selectedDiagnostic }
        set { diagnosticsState.selectedDiagnostic = newValue }
    }

    var saveCleanerRunning: Bool {
        get { saveCleanerState.running }
        set { saveCleanerState.running = newValue }
    }
    var saveCleanerProgress: Double {
        get { saveCleanerState.progress }
        set { saveCleanerState.progress = newValue }
    }
    var saveCleanerStatus: String {
        get { saveCleanerState.status }
        set { saveCleanerState.status = newValue }
    }
    var saveCleanerStatusKind: OperationStatusKind {
        get { saveCleanerState.statusKind }
        set { saveCleanerState.statusKind = newValue }
    }
    var saveCleanerReport: SaveCleanerReport? {
        get { saveCleanerState.report }
        set { saveCleanerState.report = newValue }
    }

    var modRemovalSearchText: String {
        get { modRemovalState.searchText }
        set { modRemovalState.searchText = newValue }
    }
    var modRemovalCandidates: [ModRemovalCandidate] {
        get { modRemovalState.candidates }
        set { modRemovalState.candidates = newValue }
    }
    var modRemovalCatalogLoading: Bool {
        get { modRemovalState.catalogLoading }
        set { modRemovalState.catalogLoading = newValue }
    }
    var modRemovalCatalogStatus: String {
        get { modRemovalState.catalogStatus }
        set { modRemovalState.catalogStatus = newValue }
    }
    var modRemovalModURL: URL? {
        get { modRemovalState.modURL }
        set { modRemovalState.modURL = newValue }
    }
    var selectedModRemovalModPaths: Set<String> {
        get { modRemovalState.selectedModPaths }
        set { modRemovalState.selectedModPaths = newValue }
    }
    var modRemovalRunning: Bool {
        get { modRemovalState.running }
        set { modRemovalState.running = newValue }
    }
    var modRemovalProgress: Double {
        get { modRemovalState.progress }
        set { modRemovalState.progress = newValue }
    }
    var modRemovalStatus: String {
        get { modRemovalState.status }
        set { modRemovalState.status = newValue }
    }
    var modRemovalStatusKind: OperationStatusKind {
        get { modRemovalState.statusKind }
        set { modRemovalState.statusKind = newValue }
    }
    var modRemovalReport: ModRemovalReport? {
        get { modRemovalState.report }
        set { modRemovalState.report = newValue }
    }
    var modRemovalRemoveMetadata: Bool {
        get { modRemovalState.removeMetadata }
        set { modRemovalState.removeMetadata = newValue }
    }
    var modRemovalSelectedStep: ModRemovalWizardStep {
        get { modRemovalState.selectedStep }
        set { modRemovalState.selectedStep = newValue }
    }

    init(
        settingsStore: any SettingsStoreProtocol,
        pathDetectionService: any PathDetectionServiceProtocol,
        updateService: any UpdateServiceProtocol,
        translationService: any TranslationUpdateServiceProtocol = TranslationUpdateService(),
        rjwOperationService: any RJWOperationServiceProtocol = RJWOperationService(),
        rjwCatalogService: any RJWCatalogServiceProtocol = RJWCatalogService(),
        rimWorldAnalyzer: any RimWorldAnalyzerProtocol = RimWorldAnalyzer(),
        saveCleanerService: any SaveCleanerServiceProtocol = SaveCleanerService(),
        modRemovalService: any ModRemovalServiceProtocol = ModRemovalService(),
        systemActions: any ApplicationSystemActionsProtocol = ApplicationSystemActions()
    ) {
        self.settingsStore = settingsStore
        self.pathDetectionService = pathDetectionService
        self.updateService = updateService
        self.translationService = translationService
        self.rjwOperationService = rjwOperationService
        self.rjwCatalogService = rjwCatalogService
        self.rimWorldAnalyzer = rimWorldAnalyzer
        self.saveCleanerService = saveCleanerService
        self.modRemovalService = modRemovalService
        self.systemActions = systemActions
        resetLocalizedText()
    }

    func localized(_ russian: String, _ english: String) -> String {
        resolvedLanguage == .english ? english : russian
    }

    func title(for page: UtilityPage) -> String {
        page.title(for: language)
    }

    func load(isUITesting: Bool) {
        if isUITesting {
            language = .english
        } else if let settings = settingsStore.load() {
            apply(settings)
        }
        resetLocalizedText()
        if !isUITesting {
            detectPaths()
        }
        refreshTranslationPage()
        refreshRJWPage()
    }

    func resetLocalizedText() {
        pathLabels[.save] = localized("Папка сохранений не выбрана", "No saves folder selected")
        pathLabels[.localMods] = localized("Папка локальных модов не выбрана", "No local Mods folder selected")
        pathLabels[.workshopMods] = localized("Папка Steam Workshop не выбрана", "No Steam Workshop folder selected")
        pathLabels[.config] = localized("ModsConfig.xml не выбран", "ModsConfig.xml is not selected")
        pathLabels[.log] = localized("Player.log не выбран", "Player.log is not selected")
        updateStatus = ""
        translationStatus = localized("Готово к проверке", "Ready to check")
        translationComponents = localized("Компоненты игры не определены.", "Game components have not been detected.")
        diagnosticsStatus = localized("Готово к сканированию", "Ready to scan")
        diagnosticsStatusKind = .idle
        diagnosticsSummary = localized("После анализа здесь появится короткий итог.", "A short summary will appear here after analysis.")
        saveCleanerStatus = localized("Выберите сейв и просканируйте неизвестные Def-ссылки.", "Choose a save and scan for unknown Def references.")
        saveCleanerStatusKind = .idle
        modRemovalCatalogStatus = localized("Нажмите обновить, чтобы найти моды в настроенных папках.", "Refresh to find mods in the configured folders.")
        modRemovalStatus = localized("Выберите сейв и мод, затем запустите сканирование.", "Choose a save and mod, then run a scan.")
        modRemovalStatusKind = .idle
        rjwCatalogMessage = localized("Загрузка каталога...", "Loading catalog...")
    }

    private func apply(_ settings: AppSettings) {
        if let path = settings.savePath, FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if url.pathExtension.lowercased() == "rws" {
                settingsState.saveDirectoryURL = url.deletingLastPathComponent()
                settingsState.saveURL = url
            } else {
                settingsState.saveDirectoryURL = url
            }
        }
        settingsState.modURLs = settings.modPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        if let path = settings.configPath, FileManager.default.fileExists(atPath: path) {
            settingsState.configURL = URL(fileURLWithPath: path)
        }
        if let path = settings.logPath, FileManager.default.fileExists(atPath: path) {
            settingsState.logURL = URL(fileURLWithPath: path)
        }
        language = settings.language ?? .system
        settingsState.preferredLanguage = language
    }

    func saveSettings() {
        do {
            try settingsStore.save(settingsState.appSettings)
        } catch {
            presentAlert(
                title: localized("Не удалось сохранить настройки", "Could not save settings"),
                message: localized("Проверьте доступ к папке Application Support.", "Check access to the Application Support folder."),
                details: error.localizedDescription
            )
        }
    }

    func refreshSaveCandidates() {
        guard let directory = settingsState.configuredPath(for: .save) else {
            saveCandidates = []
            settingsState.saveURL = nil
            pathLabels[.save] = localized("Папка сохранений не выбрана", "No saves folder selected")
            return
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        saveCandidates = files.compactMap { file in
            guard file.pathExtension.lowercased() == "rws" else { return nil }
            let modifiedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return SaveCandidate(url: file.resolvingSymlinksInPath(), modifiedAt: modifiedAt)
        }.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }

        if saveSelectionIsUserSelected,
           let selected = settingsState.saveURL,
           saveCandidates.contains(where: { $0.url == selected.resolvingSymlinksInPath() }) {
            return
        }
        settingsState.saveURL = saveCandidates.first?.url
        saveSelectionIsUserSelected = false
    }

    func selectSave(_ url: URL?) {
        settingsState.saveURL = url?.resolvingSymlinksInPath()
        saveSelectionIsUserSelected = url != nil
    }

    func detectPaths() {
        detectedPathAvailable.removeAll()
        if let saveDirectory = settingsState.saveDirectoryURL {
            pathLabels[.save] = saveDirectory.path
        } else if let save = pathDetectionService.latestSave() {
            settingsState.suggestedSaveDirectoryURL = save.deletingLastPathComponent()
            settingsState.suggestedSaveURL = save
            pathLabels[.save] = localized("Найдено: ", "Detected: ") + save.deletingLastPathComponent().path
            detectedPathAvailable.insert(.save)
        }
        refreshSaveCandidates()

        let localMods = settingsState.modURLs.filter { !$0.path.contains("/workshop/content/294100") }
        let workshopMods = settingsState.modURLs.filter { $0.path.contains("/workshop/content/294100") }
        if let local = localMods.first(where: { $0.lastPathComponent == "Mods" }) ?? localMods.first {
            pathLabels[.localMods] = local.path
        } else if let local = pathDetectionService.detectedLocalModDirectories().first(where: { $0.lastPathComponent == "Mods" }) ?? pathDetectionService.detectedLocalModDirectories().first {
            settingsState.suggestedLocalModsURL = local
            pathLabels[.localMods] = localized("Найдено: ", "Detected: ") + local.path
            detectedPathAvailable.insert(.localMods)
        }

        if let workshop = workshopMods.first {
            pathLabels[.workshopMods] = workshop.path
        } else if let workshop = pathDetectionService.detectedWorkshopModDirectories().first {
            settingsState.suggestedWorkshopModsURL = workshop
            pathLabels[.workshopMods] = localized("Найдено: ", "Detected: ") + workshop.path
            detectedPathAvailable.insert(.workshopMods)
        }

        if let config = settingsState.configURL {
            pathLabels[.config] = config.path
        } else if let config = pathDetectionService.detectedConfig() {
            settingsState.suggestedConfigURL = config
            pathLabels[.config] = localized("Найдено: ", "Detected: ") + config.path
            detectedPathAvailable.insert(.config)
        }

        if let log = settingsState.logURL {
            pathLabels[.log] = log.path
        } else if let log = pathDetectionService.detectedLog() {
            settingsState.suggestedLogURL = log
            pathLabels[.log] = localized("Найдено: ", "Detected: ") + log.path
            detectedPathAvailable.insert(.log)
        }
        refreshTranslationPage()
    }

    func useDetectedPath(_ kind: SettingsPathKind) {
        guard let url = settingsState.configuredPath(for: kind) else { return }
        switch kind {
        case .save:
            settingsState.saveDirectoryURL = url
            settingsState.saveURL = nil
            saveSelectionIsUserSelected = false
        case .localMods:
            settingsState.modURLs.removeAll { !$0.path.contains("/workshop/content/294100") }
            settingsState.modURLs.append(url)
            addDataFolderIfPresent(forModsURL: url)
        case .workshopMods:
            settingsState.modURLs.removeAll { $0.path.contains("/workshop/content/294100") }
            settingsState.modURLs.append(url)
        case .config:
            settingsState.configURL = url
        case .log:
            settingsState.logURL = url
        }
        pathLabels[kind] = url.path
        detectedPathAvailable.remove(kind)
        if kind == .save {
            refreshSaveCandidates()
        }
        if kind == .localMods || kind == .workshopMods {
            resetModRemovalCatalog()
        }
        saveSettings()
        refreshTranslationPage()
    }

    func choosePath(_ kind: SettingsPathKind) {
        let result: URL?
        switch kind {
        case .save:
            result = openPanel(files: false, directories: true, suggested: settingsState.saveDirectoryURL ?? pathDetectionService.latestSave()?.deletingLastPathComponent(), message: localized("Выберите папку сохранений RimWorld", "Choose the RimWorld saves folder"))
        case .localMods:
            result = openPanel(files: false, directories: true, suggested: settingsState.configuredPath(for: .localMods), message: localized("Выберите локальную папку RimWorld/Mods", "Choose the local RimWorld/Mods folder"))
        case .workshopMods:
            result = openPanel(files: false, directories: true, suggested: settingsState.configuredPath(for: .workshopMods), message: localized("Выберите папку Steam Workshop/294100", "Choose the Steam Workshop/294100 folder"))
        case .config:
            result = openPanel(files: true, directories: false, types: ["xml"], suggested: settingsState.configURL ?? pathDetectionService.detectedConfig(), message: localized("Выберите ModsConfig.xml", "Choose ModsConfig.xml"))
        case .log:
            result = openPanel(files: true, directories: false, types: ["log", "txt"], suggested: settingsState.logURL ?? pathDetectionService.detectedLog(), message: localized("Выберите Player.log", "Choose Player.log"))
        }
        guard let url = result else { return }
        switch kind {
        case .save:
            settingsState.saveDirectoryURL = url
            settingsState.saveURL = nil
            saveSelectionIsUserSelected = false
        case .localMods:
            settingsState.modURLs.removeAll { !$0.path.contains("/workshop/content/294100") }
            settingsState.modURLs.append(url)
            addDataFolderIfPresent(forModsURL: url)
        case .workshopMods:
            settingsState.modURLs.removeAll { $0.path.contains("/workshop/content/294100") }
            settingsState.modURLs.append(url)
        case .config:
            settingsState.configURL = url
        case .log:
            settingsState.logURL = url
        }
        pathLabels[kind] = url.path
        if kind == .save {
            refreshSaveCandidates()
        }
        if kind == .localMods || kind == .workshopMods {
            resetModRemovalCatalog()
        }
        saveSettings()
        refreshTranslationPage()
    }

    private func addDataFolderIfPresent(forModsURL url: URL) {
        guard url.lastPathComponent.caseInsensitiveCompare("Mods") == .orderedSame else { return }
        let data = url.deletingLastPathComponent().appendingPathComponent("Data", isDirectory: true)
        if FileManager.default.fileExists(atPath: data.path), !settingsState.modURLs.contains(data) {
            settingsState.modURLs.append(data)
        }
    }

    func openConfiguredPath(_ kind: SettingsPathKind) {
        guard let url = settingsState.configuredPath(for: kind) else { return }
        if url.hasDirectoryPath {
            systemActions.open(url)
        } else {
            systemActions.reveal(url)
        }
    }

    func changeLanguage(_ value: AppLanguage) {
        settingsState.preferredLanguage = value
        language = value
        saveSettings()
        resetLocalizedText()
        detectPaths()
    }

    func checkForUpdates() {
        updateCheckTask?.cancel()
        isCheckingUpdates = true
        updateStatus = localized("Проверка...", "Checking...")
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        updateCheckTask = Task { [weak self] in
            guard let self else { return }
            defer { updateCheckTask = nil }
            do {
                let release = try await updateService.latestRelease(currentVersion: current)
                try Task.checkCancellation()
                self.isCheckingUpdates = false
                guard let release else {
                    self.updateStatus = self.localized("Установлена актуальная версия", "You're up to date")
                    return
                }
                let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                self.updateStatus = self.localized("Доступна версия \(latest)", "Version \(latest) is available")
                if let url = URL(string: release.htmlURL) {
                    self.systemActions.open(url)
                }
            } catch is CancellationError {
                return
            } catch {
                self.isCheckingUpdates = false
                self.updateStatus = self.localized("Не удалось проверить обновления", "Could not check for updates")
                self.updateStatus += "\n" + error.localizedDescription
            }
        }
    }

    func rimWorldApplication() -> URL? {
        for source in settingsState.modURLs {
            var candidate = source.standardizedFileURL
            while candidate.path != "/" {
                if candidate.pathExtension.lowercased() == "app",
                   candidate.lastPathComponent == "RimWorldMac.app",
                   FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Data/Core/Languages").path) {
                    return candidate
                }
                candidate.deleteLastPathComponent()
            }
        }
        return nil
    }

    func installedTranslationComponents(in gameURL: URL) -> [String] {
        let dataURL = gameURL.appendingPathComponent("Data", isDirectory: true)
        let children = (try? FileManager.default.contentsOfDirectory(at: dataURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return children.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Languages", isDirectory: true).path)
        }.map(\.lastPathComponent).sorted()
    }

    func refreshTranslationPage() {
        guard !translationService.isRunning else { return }
        guard let gameURL = rimWorldApplication() else {
            translationComponents = localized("Укажите папку Data или Mods в разделе Настройки.", "Choose a Data or Mods folder in Settings.")
            translationStatus = localized("Требуется папка игры", "Game folder required")
            translationStatusKind = .warning
            return
        }
        let components = installedTranslationComponents(in: gameURL)
        translationComponents = components.isEmpty ? localized("Компоненты не найдены.", "No components found.") : components.joined(separator: ", ")
        translationStatus = components.isEmpty ? localized("Компоненты не найдены", "No components found") : localized("Готово к обновлению", "Ready to update")
        translationStatusKind = components.isEmpty ? .warning : .ready
    }

    func updateTranslation() {
        if translationService.isRunning {
            translationOperationState.cancellationRequested = true
            translationStatus = localized("Отмена обновления...", "Cancelling update...")
            translationTask?.cancel()
            translationService.cancel()
            return
        }
        guard let gameURL = rimWorldApplication() else {
            refreshTranslationPage()
            return
        }
        translationOperationState.resetForRun()
        translationConsole = ""
        translationRecentOutput = ""
        translationProgress = 0
        translationRunning = true
        translationStatusKind = .running
        translationStatus = localized("Подготовка обновления перевода", "Preparing translation update")
        translationTask = Task { [weak self] in
            guard let self else { return }
            defer { translationTask = nil }
            do {
                for try await update in translationService.updates(gameURL: gameURL) {
                    handleTranslationProgress(update)
                }
                finishTranslation(.success(()))
            } catch {
                finishTranslation(.failure(error))
            }
        }
    }

    private func handleTranslationProgress(_ update: OperationProgress) {
        if update.percent > 0 { translationProgress = update.percent }
        if !update.status.isEmpty { translationStatus = localizedToolText(update.status) }
        if let output = update.output {
            appendTranslationConsole(localizedToolText(output) + "\n")
        }
    }

    private func appendTranslationConsole(_ text: String) {
        translationConsole += text
        translationConsole = String(translationConsole.suffix(160_000))
        translationRecentOutput = recentOutput(from: translationConsole)
    }

    private func finishTranslation(_ result: Result<Void, Error>) {
        translationRunning = false
        if translationOperationState.cancellationRequested {
            translationStatus = localized("Обновление отменено", "Update cancelled")
            translationStatusKind = .idle
            return
        }
        switch result {
        case .success:
            translationProgress = 100
            translationStatus = localized("Обновление перевода завершено", "Translation update completed")
            translationStatusKind = .success
            systemActions.playSuccessSound()
        case .failure(let error):
            translationStatus = localized("Не удалось обновить перевод", "Could not update translation")
            translationStatusKind = .error
            appendTranslationConsole(error.localizedDescription + "\n")
            systemActions.playFailureSound()
        }
    }

    func rjwModsDirectory() -> URL? {
        if let gameURL = rimWorldApplication() {
            let mods = gameURL.appendingPathComponent("Mods", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: mods.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return mods
            }
        }
        return settingsState.modURLs.first { $0.lastPathComponent.caseInsensitiveCompare("Mods") == .orderedSame }
    }

    func refreshRJWPage() {
        guard !rjwOperationService.isRunning else { return }
        guard rjwModsDirectory() != nil else {
            rjwCatalogMessage = localized("Сначала подтвердите локальную папку RimWorld/Mods в Настройках.", "Choose the local RimWorld/Mods folder in Settings first.")
            return
        }
        if rjwProviders.isEmpty {
            reloadRJWProviders()
        } else {
            detectInstalledRJWProviders()
        }
    }

    func reloadRJWProviders() {
        guard !rjwOperationService.isRunning else { return }
        rjwCatalogTask?.cancel()
        rjwLoadingCatalog = true
        rjwCatalogMessage = localized("Загрузка каталога...", "Loading catalog...")
        rjwCatalogTask = Task { [weak self] in
            guard let self else { return }
            defer { rjwCatalogTask = nil }
            do {
                let items = try await rjwCatalogService.load()
                try Task.checkCancellation()
                rjwLoadingCatalog = false
                rjwProviders = items.map { ($0.category, $0.provider) }
                detectInstalledRJWProviders()
                selectedRJWProviderNames = installedRJWProviderNames
                rjwCatalogMessage = ""
            } catch is CancellationError {
                return
            } catch {
                rjwLoadingCatalog = false
                rjwCatalogMessage = [
                    localized("Не удалось загрузить каталог", "Could not load catalog"),
                    localized("Проверьте подключение к интернету и повторите попытку.", "Check your internet connection and try again."),
                    error.localizedDescription
                ].joined(separator: "\n")
            }
        }
    }

    func detectInstalledRJWProviders() {
        guard let modsURL = rjwModsDirectory() else {
            installedRJWProviderNames = []
            return
        }
        installedRJWProviderNames = Set(rjwProviders.compactMap { item in
            FileManager.default.fileExists(atPath: modsURL.appendingPathComponent(item.provider.name).path) ? item.provider.name : nil
        })
    }

    func applyRJWSelection() {
        if rjwOperationService.isRunning {
            rjwOperationState.cancellationRequested = true
            rjwStatus = localized("Остановка операции...", "Stopping operation...")
            rjwTask?.cancel()
            rjwOperationService.cancel()
            return
        }
        guard let modsURL = rjwModsDirectory() else {
            rjwStatus = localized("Не найдена папка Mods.", "The Mods folder was not found.")
            rjwStatusKind = .error
            return
        }
        detectInstalledRJWProviders()
        var operations: [RJWOperation] = []
        for item in rjwProviders where selectedRJWProviderNames.contains(item.provider.name) {
            operations.append(.install(item.provider))
        }
        guard !operations.isEmpty else {
            rjwStatus = localized("Нет выбранных операций", "No operations selected")
            rjwStatusKind = .idle
            return
        }
        startRJWOperations(operations, modsURL: modsURL)
    }

    func deleteRJWProvider(named name: String) {
        guard !rjwOperationService.isRunning else { return }
        guard let modsURL = rjwModsDirectory() else {
            rjwStatus = localized("Не найдена папка Mods.", "The Mods folder was not found.")
            rjwStatusKind = .error
            return
        }
        detectInstalledRJWProviders()
        guard installedRJWProviderNames.contains(name) else {
            rjwStatus = localized("Мод уже не установлен", "The mod is already not installed")
            rjwStatusKind = .idle
            return
        }
        startRJWOperations([.delete(name)], modsURL: modsURL)
    }

    private func startRJWOperations(_ operations: [RJWOperation], modsURL: URL) {
        rjwOperationState.resetForRun()
        rjwConsole = ""
        rjwRecentOutput = ""
        rjwProgress = 0
        rjwRunning = true
        rjwStatusKind = .running
        rjwStatus = localized("Подготовка обновления модов", "Preparing mod update")
        rjwTask = Task { [weak self] in
            guard let self else { return }
            defer { rjwTask = nil }
            do {
                for try await update in rjwOperationService.updates(operations: operations, modsURL: modsURL) {
                    handleRJWProgress(update)
                }
                finishRJW(.success(()))
            } catch {
                finishRJW(.failure(error))
            }
        }
    }

    private func handleRJWProgress(_ update: OperationProgress) {
        if update.percent > 0 { rjwProgress = update.percent }
        if !update.status.isEmpty { rjwStatus = localizedToolText(update.status) }
        if let output = update.output { appendRJWConsole(localizedToolText(output) + "\n") }
    }

    private func appendRJWConsole(_ text: String) {
        rjwConsole += text
        rjwConsole = String(rjwConsole.suffix(160_000))
        rjwRecentOutput = recentOutput(from: rjwConsole)
    }

    private func finishRJW(_ result: Result<Void, Error>) {
        rjwRunning = false
        if rjwOperationState.cancellationRequested {
            rjwStatus = localized("Операция RJW отменена", "RJW operation cancelled")
            rjwStatusKind = .idle
            detectInstalledRJWProviders()
            selectedRJWProviderNames = installedRJWProviderNames
            return
        }
        switch result {
        case .success:
            rjwProgress = 100
            rjwStatus = localized("Обновление модов завершено", "Mod update completed")
            rjwStatusKind = .success
            detectInstalledRJWProviders()
            selectedRJWProviderNames = installedRJWProviderNames
            systemActions.playSuccessSound()
        case .failure(let error):
            if case RJWOperationError.completedWithFailures = error {
                rjwStatus = localized("Операция RJW завершена с ошибками", "RJW operation completed with errors")
                rjwStatusKind = .warning
            } else {
                rjwStatus = localized("Операция RJW завершилась с ошибкой", "RJW operation failed")
                rjwStatusKind = .error
                appendRJWConsole(error.localizedDescription + "\n")
            }
            detectInstalledRJWProviders()
            systemActions.playFailureSound()
        }
    }

    func runScanner() {
        runDiagnostics()
        scanSaveCleaner()
    }

    func runDiagnostics() {
        guard let saveURL = settingsState.saveURL else { return }
        diagnosticsTask?.cancel()
        diagnosticsRunning = true
        diagnosticsStatus = localized("Сканирую сохранение...", "Scanning save...")
        diagnosticsStatusKind = .running
        diagnosticsSummary = localized("Анализирую сохранение...", "Analyzing save...")
        diagnosticCategories = []
        selectedDiagnostic = nil
        let mods = settingsState.modURLs
        let config = settingsState.configURL
        let log = settingsState.logURL
        diagnosticsTask = Task {
            defer { diagnosticsTask = nil }
            do {
                let report = try await rimWorldAnalyzer.analyzeAsync(save: saveURL, modDirectories: mods, config: config, log: log)
                try Task.checkCancellation()
                diagnosticsSummary = formatSummary(report)
                diagnosticCategories = makeDiagnosticGroups(report)
                selectedDiagnostic = diagnosticCategories.first?.problems.first
                let problemCount = report.missingMods.count
                    + report.structuralIssues.filter { $0.level == "problem" }.count
                    + report.saveFindings.count
                    + report.logIssues.count
                diagnosticsStatus = localized("Сканирование завершено. Проблем: \(problemCount)", "Scan completed. Problems: \(problemCount)")
                diagnosticsStatusKind = problemCount == 0 ? .success : .warning
                diagnosticsRunning = false
            } catch is CancellationError {
                return
            } catch {
                diagnosticsStatus = [
                    localized("Не удалось выполнить сканирование", "Could not run scanner"),
                    localized("Проверьте выбранное сохранение и доступ к связанным файлам.", "Check the selected save and access to the related files."),
                    error.localizedDescription
                ].joined(separator: "\n")
                diagnosticsStatusKind = .error
                diagnosticsRunning = false
            }
        }
    }

    func resetModRemovalCatalog() {
        modRemovalCandidates = []
        modRemovalModURL = nil
        selectedModRemovalModPaths = []
        modRemovalReport = nil
        modRemovalCatalogStatus = localized("Нажмите обновить, чтобы найти моды в настроенных папках.", "Refresh to find mods in the configured folders.")
        modRemovalStatus = localized("Выберите сейв и мод, затем запустите сканирование.", "Choose a save and mod, then run a scan.")
        modRemovalStatusKind = .idle
    }

    func refreshModRemovalCandidates() {
        guard !modRemovalCatalogLoading else { return }
        let roots = settingsState.modURLs
        guard !roots.isEmpty else {
            modRemovalCatalogStatus = localized("Сначала укажите папку локальных модов или Steam Workshop в Настройках.", "Choose the local mods or Steam Workshop folder in Settings first.")
            modRemovalCandidates = []
            modRemovalModURL = nil
            return
        }

        modRemovalCatalogLoading = true
        modRemovalCatalogStatus = localized("Ищу моды...", "Searching mods...")
        modRemovalCatalogTask?.cancel()
        modRemovalCatalogTask = Task {
            defer { modRemovalCatalogTask = nil }
            let candidates = await modRemovalService.findCandidatesAsync(in: roots, includeOfficial: false)
            guard !Task.isCancelled else { return }

            modRemovalCandidates = candidates
            modRemovalCatalogLoading = false
            let candidatePaths = Set(candidates.map(\.id))
            selectedModRemovalModPaths.formIntersection(candidatePaths)
            if let selected = modRemovalModURL, !candidates.contains(where: { $0.url == selected }) {
                modRemovalModURL = nil
                modRemovalReport = nil
            }
            modRemovalCatalogStatus = candidates.isEmpty
                ? localized("Моды не найдены. Проверьте пути в Настройках.", "No mods found. Check paths in Settings.")
                : localized("Найдено модов: \(candidates.count)", "Mods found: \(candidates.count)")
        }
    }

    func selectModRemovalCandidate(_ candidate: ModRemovalCandidate) {
        guard !candidate.isOfficialContent else { return }
        modRemovalModURL = candidate.url
        selectedModRemovalModPaths = [candidate.id]
        modRemovalReport = nil
        modRemovalStatus = localized("Мод выбран. Запустите сканирование.", "Mod selected. Run a scan.")
        modRemovalStatusKind = .ready
    }

    func setModRemovalCandidate(_ candidate: ModRemovalCandidate, selected: Bool) {
        guard !candidate.isOfficialContent else { return }
        if selected {
            selectedModRemovalModPaths.insert(candidate.id)
            modRemovalModURL = candidate.url
        } else {
            selectedModRemovalModPaths.remove(candidate.id)
            modRemovalModURL = selectedModRemovalCandidates.first?.url
        }
        modRemovalReport = nil
        modRemovalStatus = selectedModRemovalModPaths.isEmpty
            ? localized("Выберите мод и запустите сканирование.", "Choose a mod and run a scan.")
            : localized("Выбрано модов: \(selectedModRemovalModPaths.count). Запустите сканирование.", "Selected mods: \(selectedModRemovalModPaths.count). Run a scan.")
        modRemovalStatusKind = selectedModRemovalModPaths.isEmpty ? .idle : .ready
    }

    var selectedModRemovalCandidates: [ModRemovalCandidate] {
        modRemovalCandidates.filter { selectedModRemovalModPaths.contains($0.id) }
    }

    func scanModRemoval() {
        guard let saveURL = settingsState.saveURL else { return }
        let modURLs = selectedModRemovalCandidates.map(\.url)
        guard !modURLs.isEmpty else { return }
        modRemovalTask?.cancel()
        modRemovalRunning = true
        modRemovalProgress = 0
        modRemovalStatus = localized("Сканирую сейв и Defs мода...", "Scanning save and mod Defs...")
        modRemovalStatusKind = .running
        modRemovalReport = nil
        let removeMetadata = modRemovalRemoveMetadata
        let configuredModURLs = settingsState.modURLs
        let configURL = settingsState.configURL
        modRemovalTask = Task {
            defer { modRemovalTask = nil }
            do {
                let protectedModURLs = await modRemovalService.activeProtectionURLsAsync(
                    configURL: configURL,
                    modURLs: configuredModURLs,
                    selectedModURLs: modURLs
                )
                let report = try await modRemovalService.scanAsync(saveURL: saveURL, modURLs: modURLs, removeMetadata: removeMetadata, protectedModURLs: protectedModURLs)
                try Task.checkCancellation()
                modRemovalReport = report
                modRemovalStatus = formatModRemovalStatus(report, applied: false)
                modRemovalStatusKind = report.matchedDefCount > 0 ? .ready : .warning
                modRemovalProgress = 100
                modRemovalRunning = false
            } catch is CancellationError {
                return
            } catch {
                modRemovalStatus = [
                    localized("Не удалось просканировать мод", "Could not scan mod"),
                    error.localizedDescription
                ].joined(separator: "\n")
                modRemovalStatusKind = .error
                modRemovalProgress = 0
                modRemovalRunning = false
            }
        }
    }

    func cleanModRemoval() {
        guard let saveURL = settingsState.saveURL else { return }
        let modURLs = selectedModRemovalCandidates.map(\.url)
        guard !modURLs.isEmpty else { return }
        modRemovalTask?.cancel()
        modRemovalRunning = true
        modRemovalProgress = 10
        modRemovalStatus = localized("Создаю очищенную копию сейва...", "Creating cleaned save copy...")
        modRemovalStatusKind = .running
        let removeMetadata = modRemovalRemoveMetadata
        let configuredModURLs = settingsState.modURLs
        let configURL = settingsState.configURL
        modRemovalTask = Task {
            defer { modRemovalTask = nil }
            do {
                let protectedModURLs = await modRemovalService.activeProtectionURLsAsync(
                    configURL: configURL,
                    modURLs: configuredModURLs,
                    selectedModURLs: modURLs
                )
                let report = try await modRemovalService.cleanAsync(saveURL: saveURL, modURLs: modURLs, mode: .conservative, removeMetadata: removeMetadata, protectedModURLs: protectedModURLs)
                try Task.checkCancellation()
                modRemovalReport = report
                modRemovalStatus = formatModRemovalStatus(report, applied: true)
                modRemovalStatusKind = .success
                modRemovalProgress = 100
                modRemovalRunning = false
                systemActions.playSuccessSound()
            } catch is CancellationError {
                return
            } catch {
                modRemovalStatus = [
                    localized("Не удалось очистить сохранение", "Could not clean save"),
                    error.localizedDescription
                ].joined(separator: "\n")
                modRemovalStatusKind = .error
                modRemovalProgress = 0
                modRemovalRunning = false
                systemActions.playFailureSound()
            }
        }
    }

    func scanSaveCleaner() {
        guard let saveURL = settingsState.saveURL else { return }
        saveCleanerTask?.cancel()
        saveCleanerRunning = true
        saveCleanerProgress = 0
        saveCleanerStatus = localized("Собираю Def'ы активных модов и проверяю сейв...", "Collecting active mod Defs and scanning the save...")
        saveCleanerStatusKind = .running
        saveCleanerReport = nil
        let modURLs = settingsState.modURLs
        let configURL = settingsState.configURL
        saveCleanerTask = Task {
            defer { saveCleanerTask = nil }
            do {
                let report = try await saveCleanerService.scanAsync(saveURL: saveURL, modDirectories: modURLs, configURL: configURL)
                try Task.checkCancellation()
                saveCleanerReport = report
                saveCleanerStatus = formatSaveCleanerStatus(report, applied: false)
                saveCleanerStatusKind = report.changeCount > 0 ? .ready : .success
                saveCleanerProgress = 100
                saveCleanerRunning = false
            } catch is CancellationError {
                return
            } catch {
                saveCleanerStatus = [
                    localized("Не удалось просканировать сейв", "Could not scan save"),
                    error.localizedDescription
                ].joined(separator: "\n")
                saveCleanerStatusKind = .error
                saveCleanerProgress = 0
                saveCleanerRunning = false
            }
        }
    }

    func cleanSaveCleaner() {
        guard let saveURL = settingsState.saveURL else { return }
        saveCleanerTask?.cancel()
        saveCleanerRunning = true
        saveCleanerProgress = 10
        saveCleanerStatus = localized("Создаю очищенную копию сейва...", "Creating cleaned save copy...")
        saveCleanerStatusKind = .running
        let modURLs = settingsState.modURLs
        let configURL = settingsState.configURL
        saveCleanerTask = Task {
            defer { saveCleanerTask = nil }
            do {
                let report = try await saveCleanerService.cleanAsync(saveURL: saveURL, modDirectories: modURLs, configURL: configURL)
                try Task.checkCancellation()
                saveCleanerReport = report
                saveCleanerStatus = formatSaveCleanerStatus(report, applied: true)
                saveCleanerStatusKind = .success
                saveCleanerProgress = 100
                saveCleanerRunning = false
                systemActions.playSuccessSound()
            } catch is CancellationError {
                return
            } catch {
                saveCleanerStatus = [
                    localized("Не удалось очистить сейв", "Could not clean save"),
                    error.localizedDescription
                ].joined(separator: "\n")
                saveCleanerStatusKind = .error
                saveCleanerProgress = 0
                saveCleanerRunning = false
                systemActions.playFailureSound()
            }
        }
    }

    private func formatModRemovalStatus(_ report: ModRemovalReport, applied: Bool) -> String {
        var lines = [
            localized("Модов выбрано: \(report.modNames?.count ?? 1)", "Selected mods: \(report.modNames?.count ?? 1)"),
            localized("Def'ов найдено: \(report.defCount)", "Defs found: \(report.defCount)"),
            localized("Def'ов встречается в сейве: \(report.matchedDefCount)", "Defs referenced in save: \(report.matchedDefCount)"),
            localized("Чужих ссылок проигнорировано: \(report.foreignReferenceCount)", "Foreign references ignored: \(report.foreignReferenceCount)")
        ]
        if let backupPath = report.backupPath {
            lines.append(localized("Backup: \(backupPath)", "Backup: \(backupPath)"))
        }
        if let outputPath = report.outputPath {
            lines.append(localized("Очищенный сейв: \(outputPath)", "Cleaned save: \(outputPath)"))
        }
        if applied {
            lines.append(localized("Оригинальный сейв не изменён.", "Original save was not changed."))
        } else if report.matchedDefCount == 0 {
            lines.append(localized("Прямых ссылок на Def'ы мода в сейве не найдено.", "No direct references to this mod's Defs were found in the save."))
        } else {
            lines.append(localized("Оригинальный сейв не будет изменён. Очистка создаст копию рядом с ним.", "The original save will not be changed. Cleanup will create a copy next to it."))
        }
        return lines.joined(separator: "\n")
    }

    private func formatSaveCleanerStatus(_ report: SaveCleanerReport, applied: Bool) -> String {
        var lines = [
            localized("Активных Def'ов собрано: \(report.activeDefCount)", "Active Defs indexed: \(report.activeDefCount)"),
            localized("Источников просканировано: \(report.scannedModCount)", "Sources scanned: \(report.scannedModCount)"),
            localized("Неизвестных Def'ов найдено: \(report.unknownDefCount)", "Unknown Defs found: \(report.unknownDefCount)"),
            localized("Запланированных изменений: \(report.changeCount)", "Planned changes: \(report.changeCount)")
        ]
        if let outputPath = report.outputPath {
            lines.append(localized("Очищенный сейв: \(outputPath)", "Cleaned save: \(outputPath)"))
        }
        if applied {
            lines.append(localized("Оригинальный сейв не изменён.", "Original save was not changed."))
        } else if report.changeCount == 0 {
            lines.append(localized("Безопасных неизвестных Def-ссылок для очистки не найдено.", "No safe unknown Def references were found for cleanup."))
        } else {
            lines.append(localized("Очистка создаст копию рядом с оригинальным сейвом.", "Cleanup will create a copy next to the original save."))
        }
        return lines.joined(separator: "\n")
    }

    private func makeDiagnosticGroups(_ report: AnalysisReport) -> [DiagnosticProblemGroup] {
        let modProblemsTitle = localized("Проблемы модов", "Mod problems")
        let structuralProblemsTitle = localized("Структура сейва", "Save structure")
        let notificationsTitle = localized("Уведомления", "Notifications")
        let logProblemsTitle = localized("Ошибки Player.log", "Player.log errors")
        let modProblems = report.missingMods.map { mod in
            DiagnosticProblemRow(category: nil, title: mod.name ?? mod.packageId, subtitle: localized("Мод не найден", "Mod not found"), details: localized("Мод: \(modLabel(mod))", "Mod: \(modLabel(mod))"))
        }
        let structuralProblems = report.structuralIssues.filter { $0.level == "problem" }.map { issue in
            DiagnosticProblemRow(
                category: nil,
                title: issue.objectName,
                subtitle: "\(issue.field): \(localizedStructuralProblem(issue.problem))",
                details: formatStructuralIssue(issue)
            )
        }
        let notifications = report.structuralIssues.filter { $0.level == "notification" }.map { issue in
            DiagnosticProblemRow(
                category: nil,
                title: issue.objectName,
                subtitle: "\(issue.field): \(localizedStructuralProblem(issue.problem))",
                details: formatStructuralIssue(issue)
            )
        }
        let logProblems = report.logIssues.map { issue in
            let relatedMods = issue.relatedMods.map(modLabel).joined(separator: ", ")
            let details = [
                localized("Серьёзность: \(localizedIssueSeverity(issue.severity))", "Severity: \(localizedIssueSeverity(issue.severity))"),
                localized("Повторов: \(issue.count)", "Occurrences: \(issue.count)"),
                issue.message,
                relatedMods.isEmpty ? nil : localized("Связанные моды: \(relatedMods)", "Related mods: \(relatedMods)"),
                issue.evidence
            ].compactMap { $0 }.joined(separator: "\n")
            return DiagnosticProblemRow(
                category: nil,
                title: localizedIssueCategory(issue.category),
                subtitle: "\(localizedIssueSeverity(issue.severity)): \(issue.message)",
                details: details
            )
        }
        return [
            DiagnosticProblemGroup(title: modProblemsTitle, problems: modProblems),
            DiagnosticProblemGroup(title: structuralProblemsTitle, problems: structuralProblems),
            DiagnosticProblemGroup(title: notificationsTitle, problems: notifications),
            DiagnosticProblemGroup(title: logProblemsTitle, problems: logProblems)
        ]
    }

    private func formatSummary(_ report: AnalysisReport) -> String {
        let structuralProblemCount = report.structuralIssues.filter { $0.level == "problem" }.count
        let notificationCount = report.structuralIssues.filter { $0.level == "notification" }.count
        return [
            localized("Сохранение: \(report.savePath)", "Save: \(report.savePath)"),
            localized("Версия игры: \(report.gameVersion ?? "не определена")", "Game version: \(report.gameVersion ?? "unknown")"),
            localized("Модов в сохранении: \(report.saveMods.count)", "Mods in save: \(report.saveMods.count)"),
            localized("Установленных модов: \(report.installedMods.count)", "Installed mods: \(report.installedMods.count)"),
            localized("Отсутствующих модов: \(report.missingMods.count)", "Missing mods: \(report.missingMods.count)"),
            localized("Структурных проблем сейва: \(structuralProblemCount)", "Save structure issues: \(structuralProblemCount)"),
            localized("Уведомлений: \(notificationCount)", "Notifications: \(notificationCount)"),
            localized("Def-ссылок просканировано: \(report.scannedDefReferences)", "Def references scanned: \(report.scannedDefReferences)"),
            localized("Проблем Player.log: \(report.logIssues.count)", "Player.log issues: \(report.logIssues.count)")
        ].joined(separator: "\n")
    }

    func localizedToolText(_ text: String) -> String {
        guard resolvedLanguage == .english else { return text }
        var result = text
        result = result.replacingOccurrences(of: "Ошибка:", with: "Error:")
        result = result.replacingOccurrences(of: "Отмена:", with: "Cancelled:")
        result = result.replacingOccurrences(of: "Подготовка обновления перевода", with: "Preparing translation update")
        result = result.replacingOccurrences(of: "Подготовка обновления модов", with: "Preparing mod update")
        result = result.replacingOccurrences(of: "Проверка версии перевода", with: "Checking translation version")
        result = result.replacingOccurrences(of: "Скачивание перевода", with: "Downloading translation")
        result = result.replacingOccurrences(of: "Проверка архива", with: "Verifying archive")
        result = result.replacingOccurrences(of: "Распаковка архива", with: "Extracting archive")
        result = result.replacingOccurrences(of: "Подготовка установки перевода", with: "Preparing translation installation")
        result = result.replacingOccurrences(of: "Установка перевода версии", with: "Installing translation version")
        result = result.replacingOccurrences(of: "Установка перевода:", with: "Installing translation:")
        result = result.replacingOccurrences(of: "Обновление перевода завершено", with: "Translation update completed")
        result = result.replacingOccurrences(of: "Обновление модов завершено с ошибками", with: "Mod update completed with errors")
        result = result.replacingOccurrences(of: "Обновление модов завершено", with: "Mod update completed")
        result = result.replacingOccurrences(of: "Обновление модов:", with: "Updating mods:")
        result = result.replacingOccurrences(of: "Скачивание Git-мода:", with: "Downloading Git mod:")
        result = result.replacingOccurrences(of: "Скачивание ZIP-мода:", with: "Downloading ZIP mod:")
        result = result.replacingOccurrences(of: "Проверка Git-мода:", with: "Checking Git mod:")
        result = result.replacingOccurrences(of: "Обновлён:", with: "Updated:")
        result = result.replacingOccurrences(of: "Без изменений:", with: "No changes:")
        result = result.replacingOccurrences(of: "Чистая установка Git-мода:", with: "Clean Git mod installation:")
        result = result.replacingOccurrences(of: "Чистая установка ZIP-мода:", with: "Clean ZIP mod installation:")
        result = result.replacingOccurrences(of: "Удаление:", with: "Removing:")
        result = result.replacingOccurrences(of: "Итог: успешно", with: "Summary: successful")
        result = result.replacingOccurrences(of: "Итог: установлено", with: "Summary: installed")
        result = result.replacingOccurrences(of: "без изменений", with: "unchanged")
        result = result.replacingOccurrences(of: "ошибок", with: "errors")
        result = result.replacingOccurrences(of: "останавливаю текущую операцию", with: "stopping the current operation")
        result = result.replacingOccurrences(of: " из ", with: " of ")
        return result
    }

    private func localizedIssueCategory(_ category: String) -> String {
        switch category {
        case "missing_definition":
            return localized("Отсутствующее определение", "Missing definition")
        case "missing_object_reference":
            return localized("Потерянная ссылка на объект", "Missing object reference")
        case "missing_type":
            return localized("Отсутствующий тип", "Missing type")
        case "serialization_error":
            return localized("Ошибка сериализации", "Serialization error")
        case "duplicate_load_id":
            return localized("Повторяющийся ID объекта", "Duplicate object ID")
        case "null_data":
            return localized("Потерянные данные", "Missing data")
        case "post_load_error":
            return localized("Ошибка завершения загрузки", "Post-load error")
        case "runtime_exception":
            return localized("Повторяющаяся ошибка интерфейса", "Runtime UI error")
        case "invalid_object_state":
            return localized("Некорректное состояние объекта", "Invalid object state")
        case "xml_error":
            return localized("Ошибка XML", "XML error")
        case "patch_error":
            return localized("Ошибка патча", "Patch error")
        case "exception":
            return localized("Исключение", "Exception")
        case "duplicate_definition":
            return localized("Повторяющееся определение", "Duplicate definition")
        default:
            return category
        }
    }

    private func localizedIssueSeverity(_ severity: String) -> String {
        switch severity {
        case "critical":
            return localized("Критично", "Critical")
        case "problem":
            return localized("Проблема", "Problem")
        case "warning":
            return localized("Предупреждение", "Warning")
        default:
            return severity
        }
    }

    private func localizedStructuralProblem(_ problem: String) -> String {
        switch problem {
        case "missing":
            return localized("нет поля", "missing field")
        case "empty":
            return localized("пусто", "empty")
        case let value where value.hasPrefix("duplicate"):
            return localized("повторяющийся ID\(value.dropFirst("duplicate".count))", "duplicate ID\(value.dropFirst("duplicate".count))")
        case let value where value.hasPrefix("target missing"):
            return localized("цель ссылки отсутствует\(value.dropFirst("target missing".count))", "reference target is missing\(value.dropFirst("target missing".count))")
        default:
            return problem
        }
    }

    private func formatStructuralIssue(_ issue: StructuralIssue) -> String {
        [
            localized("Объект: \(issue.objectName) [\(issue.objectId)]", "Object: \(issue.objectName) [\(issue.objectId)]"),
            localized("Тип: \(issue.objectType)", "Type: \(issue.objectType)"),
            localized("Поле: \(issue.field)", "Field: \(issue.field)"),
            localized("Проблема: \(localizedStructuralProblem(issue.problem))", "Problem: \(localizedStructuralProblem(issue.problem))")
        ].joined(separator: "\n")
    }

    private func localizedSaveFindingKind(_ kind: String) -> String {
        switch kind {
        case "def_from_inactive_mod":
            return localized("Def из неактивного мода", "Def from inactive mod")
        case "class_from_inactive_mod":
            return localized("Class из неактивного мода", "Class from inactive mod")
        case "class_from_missing_mod":
            return localized("Class из отсутствующего мода", "Class from missing mod")
        default:
            return kind
        }
    }

    private func formatSaveFinding(_ finding: SaveFinding) -> String {
        [
            localized("Значение: \(finding.value)", "Value: \(finding.value)"),
            localized("Тип: \(localizedSaveFindingKind(finding.kind))", "Type: \(localizedSaveFindingKind(finding.kind))"),
            localized("Количество: \(finding.count)", "Count: \(finding.count)"),
            localized("Мод: \(finding.relatedMod.map(modLabel) ?? "не определён")", "Mod: \(finding.relatedMod.map(modLabel) ?? "unknown")")
        ].joined(separator: "\n")
    }

    private func modLabel(_ mod: ModInfo) -> String {
        mod.name.map { "\($0) (\(mod.packageId))" } ?? mod.packageId
    }

    private func recentOutput(from text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(4)
            .joined(separator: "\n")
    }

    private func openPanel(files: Bool, directories: Bool, types: [String] = [], suggested: URL? = nil, message: String) -> URL? {
        systemActions.chooseURL(
            files: files,
            directories: directories,
            types: types,
            suggested: suggested,
            message: message,
            prompt: localized("Подтвердить", "Choose")
        )
    }

    func openApplicationRepository() {
        openExternalURL(URL(string: "https://github.com/SomaLancet/RimWorld-Utilities")!)
    }

    func openProvidersRepository() {
        openExternalURL(URL(string: "https://gitgud.io/AblativeAbsolute/libidinous_loader_providers")!)
    }

    func openTranslationRepository() {
        openExternalURL(URL(string: "https://github.com/Ludeon/RimWorld-ru")!)
    }

    func openExternalURL(_ url: URL) {
        systemActions.open(url)
    }

    func cancelRunningOperations() {
        translationOperationState.cancellationRequested = true
        rjwOperationState.cancellationRequested = true
        updateCheckTask?.cancel()
        translationTask?.cancel()
        rjwCatalogTask?.cancel()
        rjwTask?.cancel()
        diagnosticsTask?.cancel()
        modRemovalCatalogTask?.cancel()
        modRemovalTask?.cancel()
        saveCleanerTask?.cancel()
        if translationService.isRunning { translationService.cancel() }
        if rjwOperationService.isRunning { rjwOperationService.cancel() }
        resetCancelledOperationState()
    }

    private func resetCancelledOperationState() {
        isCheckingUpdates = false
        rjwLoadingCatalog = false
        diagnosticsRunning = false
        modRemovalCatalogLoading = false
        modRemovalRunning = false
        saveCleanerRunning = false

        if translationRunning {
            translationRunning = false
            translationStatus = localized("Обновление отменено", "Update cancelled")
            translationStatusKind = .idle
        }

        if rjwRunning {
            rjwRunning = false
            rjwStatus = localized("Операция RJW отменена", "RJW operation cancelled")
            rjwStatusKind = .idle
        }

        if diagnosticsStatusKind == .running {
            diagnosticsStatus = localized("Сканирование отменено", "Scan cancelled")
            diagnosticsStatusKind = .idle
        }

        if modRemovalStatusKind == .running {
            modRemovalStatus = localized("Операция удаления мода отменена", "Mod removal operation cancelled")
            modRemovalStatusKind = .idle
        }

        if saveCleanerStatusKind == .running {
            saveCleanerStatus = localized("Очистка сейва отменена", "Save cleanup cancelled")
            saveCleanerStatusKind = .idle
        }
    }

    func toggleSidebar() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }

    private func presentAlert(title: String, message: String, details: String?) {
        systemActions.presentWarning(title: title, message: message, details: details)
    }
}
