import Foundation
import XCTest
@testable import RimWorld_Utilities

final class ControllerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testSettingsStateResolvesConfiguredPaths() throws {
        let save = root.appendingPathComponent("Colony.rws")
        let saves = root.appendingPathComponent("Saves", isDirectory: true)
        let localMods = root.appendingPathComponent("RimWorld/Mods", isDirectory: true)
        let data = root.appendingPathComponent("RimWorld/Data", isDirectory: true)
        let workshop = root.appendingPathComponent("Steam/workshop/content/294100", isDirectory: true)
        let config = root.appendingPathComponent("ModsConfig.xml")
        let log = root.appendingPathComponent("Player.log")

        let state = SettingsState(
            saveDirectoryURL: saves,
            saveURL: save,
            modURLs: [workshop, data, localMods],
            configURL: config,
            logURL: log,
            preferredLanguage: .english
        )

        XCTAssertEqual(state.configuredPath(for: .save), saves)
        XCTAssertEqual(state.configuredPath(for: .localMods), localMods)
        XCTAssertEqual(state.configuredPath(for: .workshopMods), workshop)
        XCTAssertEqual(state.configuredPath(for: .config), config)
        XCTAssertEqual(state.configuredPath(for: .log), log)
        XCTAssertEqual(state.appSettings.savePath, saves.path)
        XCTAssertEqual(state.appSettings.modPaths, [workshop.path, data.path, localMods.path])
        XCTAssertEqual(state.appSettings.language, .english)
    }

    func testTranslationOperationStateBuffersOutputAndComponents() {
        var state = TranslationOperationState()

        XCTAssertEqual(state.consumeBufferedLines("first\nsecond"), ["first"])
        XCTAssertEqual(state.outputBuffer, "second")
        XCTAssertEqual(state.consumeBufferedLines("\nthird\n"), ["second", "third"])
        XCTAssertEqual(state.outputBuffer, "")

        state.recordInstalledComponent(from: "Установка перевода: Core (ru)")
        XCTAssertEqual(state.updatedComponents, ["Core"])

        state.errors = ["error"]
        state.cancellationRequested = true
        state.resetForRun()
        XCTAssertEqual(state.outputBuffer, "")
        XCTAssertTrue(state.errors.isEmpty)
        XCTAssertTrue(state.updatedComponents.isEmpty)
        XCTAssertFalse(state.cancellationRequested)
    }

    @MainActor func testApplicationModelDetectsPathsAndSavesSettings() throws {
        let store = MockSettingsStore()
        let detection = MockPathDetectionService()
        detection.saveURL = try createFile("Detected/Colony.rws")
        detection.configURL = try createFile("Detected/ModsConfig.xml")
        detection.logURL = try createFile("Detected/Player.log")
        detection.localModDirectories = [try createDirectory("Detected/Mods")]
        detection.workshopModDirectories = [try createDirectory("Detected/workshop/content/294100")]
        let model = makeModel(settingsStore: store, pathDetectionService: detection)

        model.detectPaths()
        model.useDetectedPath(.save)
        model.useDetectedPath(.localMods)
        model.useDetectedPath(.workshopMods)
        model.useDetectedPath(.config)
        model.useDetectedPath(.log)

        let saved = try XCTUnwrap(store.savedSettings.last)
        XCTAssertEqual(saved.savePath, detection.saveURL?.deletingLastPathComponent().path)
        XCTAssertEqual(Set(saved.modPaths), Set((detection.localModDirectories + detection.workshopModDirectories).map(\.path)))
        XCTAssertEqual(saved.configPath, detection.configURL?.path)
        XCTAssertEqual(saved.logPath, detection.logURL?.path)
    }

    @MainActor func testApplicationModelRefreshSaveCandidatesAutoSelectsLatestUntilUserChooses() throws {
        let saves = try createDirectory("Saves")
        let older = try createFile("Saves/Older.rws")
        let newer = try createFile("Saves/Newer.rws")
        try setModificationDate(Date(timeIntervalSince1970: 1_000), for: older)
        try setModificationDate(Date(timeIntervalSince1970: 2_000), for: newer)
        let model = makeModel()
        model.settingsState.saveDirectoryURL = saves

        model.refreshSaveCandidates()

        XCTAssertEqual(model.saveCandidates.map(\.url), [newer, older])
        XCTAssertEqual(model.settingsState.saveURL, newer)

        model.selectSave(older)
        try setModificationDate(Date(timeIntervalSince1970: 3_000), for: newer)
        model.refreshSaveCandidates()

        XCTAssertEqual(model.settingsState.saveURL, older)

        try FileManager.default.removeItem(at: older)
        model.refreshSaveCandidates()

        XCTAssertEqual(model.settingsState.saveURL, newer)
    }

    @MainActor func testApplicationModelFindsRimWorldApplicationFromModsPath() throws {
        let app = try createDirectory("RimWorldMac.app")
        _ = try createDirectory("RimWorldMac.app/Data/Core/Languages")
        let mods = try createDirectory("RimWorldMac.app/Mods")
        let model = makeModel()
        model.settingsState.modURLs = [mods]

        XCTAssertEqual(model.rimWorldApplication(), app)
        XCTAssertEqual(model.installedTranslationComponents(in: app), ["Core"])
    }

    @MainActor func testApplicationModelPrefersModsFolderInsideDetectedGame() throws {
        let expectedMods = try createDirectory("RimWorldMac.app/Mods")
        _ = try createDirectory("RimWorldMac.app/Data/Core/Languages")
        let fallbackMods = try createDirectory("Fallback/Mods")
        let model = makeModel()
        model.settingsState.modURLs = [fallbackMods, expectedMods]

        XCTAssertEqual(model.rjwModsDirectory(), expectedMods)
    }

    @MainActor func testApplicationModelLocalizesToolText() {
        let model = makeModel()
        model.language = .english

        XCTAssertEqual(model.localizedToolText("Проверка архива"), "Verifying archive")
        XCTAssertEqual(model.localizedToolText("Обновлён: Core"), "Updated: Core")
    }

    @MainActor func testApplicationModelCancelRunningOperationsResetsBusyState() {
        let model = makeModel()
        model.isCheckingUpdates = true
        model.translationRunning = true
        model.translationStatusKind = .running
        model.rjwLoadingCatalog = true
        model.rjwRunning = true
        model.rjwStatusKind = .running
        model.diagnosticsRunning = true
        model.diagnosticsStatusKind = .running
        model.modRemovalCatalogLoading = true
        model.modRemovalRunning = true
        model.modRemovalStatusKind = .running
        model.saveCleanerRunning = true
        model.saveCleanerStatusKind = .running

        model.cancelRunningOperations()

        XCTAssertFalse(model.isCheckingUpdates)
        XCTAssertFalse(model.translationRunning)
        XCTAssertEqual(model.translationStatus, "Update cancelled")
        XCTAssertEqual(model.translationStatusKind, .idle)
        XCTAssertFalse(model.rjwLoadingCatalog)
        XCTAssertFalse(model.rjwRunning)
        XCTAssertEqual(model.rjwStatus, "RJW operation cancelled")
        XCTAssertEqual(model.rjwStatusKind, .idle)
        XCTAssertFalse(model.diagnosticsRunning)
        XCTAssertEqual(model.diagnosticsStatus, "Scan cancelled")
        XCTAssertEqual(model.diagnosticsStatusKind, .idle)
        XCTAssertFalse(model.modRemovalCatalogLoading)
        XCTAssertFalse(model.modRemovalRunning)
        XCTAssertEqual(model.modRemovalStatus, "Mod removal operation cancelled")
        XCTAssertEqual(model.modRemovalStatusKind, .idle)
        XCTAssertFalse(model.saveCleanerRunning)
        XCTAssertEqual(model.saveCleanerStatus, "Save cleanup cancelled")
        XCTAssertEqual(model.saveCleanerStatusKind, .idle)
    }

    func testUserFacingErrorNormalizesDetails() {
        let presentation = UserFacingError(
            title: "Failure",
            message: "Try again.",
            details: "  Technical details  \n"
        )

        XCTAssertEqual(presentation.details, "Technical details")
        XCTAssertEqual(presentation.informativeText, "Try again.\n\nTechnical details")
    }

    @MainActor func testApplicationModelHandlesTranslationProgressAndSuccess() async throws {
        let mock = MockTranslationUpdateService()
        let model = try makeTranslationModel(service: mock)

        model.updateTranslation()
        await waitForAsyncModelUpdates()

        XCTAssertEqual(mock.startCallCount, 1)
        XCTAssertTrue(model.translationRunning)
        mock.sendProgress(.init(percent: 45, status: "Проверка архива", output: "Обновлён: Core"))
        let didReceiveProgress = await waitUntil { model.translationProgress == 45 }
        XCTAssertTrue(didReceiveProgress)
        XCTAssertEqual(model.translationProgress, 45)
        XCTAssertEqual(model.translationStatus, "Verifying archive")
        XCTAssertTrue(model.translationConsole.contains("Updated: Core"))

        mock.complete(with: .success(()))
        let didComplete = await waitUntil { !model.translationRunning }
        XCTAssertTrue(didComplete)
        XCTAssertFalse(model.translationRunning)
        XCTAssertEqual(model.translationStatus, "Translation update completed")
        XCTAssertEqual(model.translationStatusKind, .success)
    }

    @MainActor func testApplicationModelHandlesTranslationFailureAndCancel() async throws {
        let mock = MockTranslationUpdateService()
        let model = try makeTranslationModel(service: mock)

        model.updateTranslation()
        await waitForAsyncModelUpdates()
        model.updateTranslation()
        XCTAssertEqual(mock.cancelCallCount, 1)
        mock.complete(with: .failure(CancellationError()))
        let didCancel = await waitUntil { model.translationStatus == "Update cancelled" }
        XCTAssertTrue(didCancel)
        XCTAssertEqual(model.translationStatus, "Update cancelled")

        model.updateTranslation()
        await waitForAsyncModelUpdates()
        mock.complete(with: .failure(TestError.failure))
        let didFail = await waitUntil { model.translationStatus == "Could not update translation" }
        XCTAssertTrue(didFail)
        XCTAssertEqual(model.translationStatus, "Could not update translation")
        XCTAssertEqual(model.translationStatusKind, .error)
        XCTAssertTrue(model.translationConsole.contains(TestError.failure.localizedDescription))
    }

    @MainActor func testApplicationModelHandlesRJWProgressAndSuccess() async throws {
        let service = MockRJWOperationService()
        let (model, mods, provider) = try makeRJWModel(service: service)

        model.applyRJWSelection()
        await waitForAsyncModelUpdates()

        XCTAssertEqual(service.startCallCount, 1)
        XCTAssertEqual(service.modsURL, mods)
        XCTAssertEqual(service.operations.count, 1)
        if case .install(let requestedProvider) = service.operations[0] {
            XCTAssertEqual(requestedProvider.name, provider.name)
        } else {
            XCTFail("Expected an install operation")
        }

        service.sendProgress(.init(percent: 60, status: "Обновление модов: Test", output: "Обновлён: Test"))
        let didReceiveProgress = await waitUntil { model.rjwProgress == 60 }
        XCTAssertTrue(didReceiveProgress)
        XCTAssertEqual(model.rjwProgress, 60)
        XCTAssertEqual(model.rjwStatus, "Updating mods: Test")
        XCTAssertTrue(model.rjwConsole.contains("Updated: Test"))

        service.complete(with: .success(()))
        let didComplete = await waitUntil { model.rjwStatusKind == .success }
        XCTAssertTrue(didComplete)
        XCTAssertEqual(model.rjwStatus, "Mod update completed")
        XCTAssertEqual(model.rjwStatusKind, .success)
    }

    @MainActor func testApplicationModelDoesNotDeleteRJWProviderWhenUnchecked() throws {
        let service = MockRJWOperationService()
        let (model, _, provider) = try makeRJWModel(service: service)
        _ = try createDirectory("RimWorldMac.app/Mods/\(provider.name)")
        model.selectedRJWProviderNames = []

        model.applyRJWSelection()

        XCTAssertEqual(service.startCallCount, 0)
        XCTAssertEqual(model.rjwStatus, "No operations selected")
    }

    @MainActor func testApplicationModelDeletesRJWProviderExplicitly() async throws {
        let service = MockRJWOperationService()
        let (model, mods, provider) = try makeRJWModel(service: service)
        _ = try createDirectory("RimWorldMac.app/Mods/\(provider.name)")

        model.deleteRJWProvider(named: provider.name)
        await waitForAsyncModelUpdates()

        XCTAssertEqual(service.startCallCount, 1)
        XCTAssertEqual(service.modsURL, mods)
        XCTAssertEqual(service.operations.count, 1)
        if case .delete(let name) = service.operations[0] {
            XCTAssertEqual(name, provider.name)
        } else {
            XCTFail("Expected a delete operation")
        }
    }

    @MainActor func testApplicationModelLoadsRJWCatalogAndShowsFailure() async throws {
        let catalog = MockRJWCatalogService()
        let model = makeModel(rjwCatalogService: catalog)
        model.settingsState.modURLs = [try createDirectory("RimWorldMac.app/Mods")]

        model.reloadRJWProviders()
        await waitForAsyncModelUpdates()
        XCTAssertEqual(catalog.loadCallCount, 1)

        let provider = try makeProvider()
        catalog.complete(with: .success([RJWCatalogItem(category: "Tests", provider: provider)]))
        let didLoadCatalog = await waitUntil { model.rjwProviders.count == 1 }
        XCTAssertTrue(didLoadCatalog)
        XCTAssertEqual(model.rjwProviders.count, 1)
        XCTAssertEqual(model.selectedRJWProviderNames, [])

        model.rjwProviders = []
        model.reloadRJWProviders()
        let didStartSecondLoad = await waitUntil { catalog.loadCallCount == 2 }
        XCTAssertTrue(didStartSecondLoad)
        catalog.complete(with: .failure(TestError.failure))
        let didShowCatalogFailure = await waitUntil { model.rjwCatalogMessage.contains("Could not load catalog") }
        XCTAssertTrue(didShowCatalogFailure)
        XCTAssertTrue(model.rjwCatalogMessage.contains("Could not load catalog"))
        XCTAssertTrue(model.rjwCatalogMessage.contains(TestError.failure.localizedDescription))
    }

    func testRJWCatalogParsesRepositoryTOML() throws {
        let data = Data(#"""
        version = 1

        [providers.extra.second]
        type = "zip"
        name = "second"
        display_name = "Beta"
        description = "ZIP provider"
        url = "https://example.com/second.zip"
        subdir = "Second Mod"
        disabled = true
        rimworld_versions = ["1.6"]

        [providers.root.first]
        type = "git"
        name = "first"
        display_name = "Alpha"
        description = "Git provider"
        info_url = "https://example.com/info"
        url = "https://example.com/first.git"
        branch = "main"
        """#.utf8)

        let items = try RJWCatalogService.decodeTOML(data)

        XCTAssertEqual(items.map(\.category), ["extra", "root"])
        XCTAssertEqual(items.map { $0.provider.name }, ["second", "first"])
        XCTAssertEqual(items[0].provider.displayName, "Beta")
        XCTAssertEqual(items[0].provider.subdir, "Second Mod")
        XCTAssertEqual(items[0].provider.disabled, true)
        XCTAssertEqual(items[0].provider.rimworldVersions, ["1.6"])
        XCTAssertEqual(items[1].provider.displayName, "Alpha")
        XCTAssertEqual(items[1].provider.branch, "main")
    }

    func testRJWCatalogFallsBackWhenPackageEndpointReturns403() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            return (response, Data("Cloudflare challenge".utf8))
        }
        let repositoryData = Data(#"""
        [providers.root.rjw]
        type = "git"
        name = "rjw"
        description = "Depravity's foundation"
        url = "https://gitgud.io/Ed86/rjw.git"
        """#.utf8)
        let service = RJWCatalogService(session: session) { repositoryData }
        let items = try await service.load()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.provider.name, "rjw")
        MockURLProtocol.requestHandler = nil
    }

    @MainActor private func makeModel(
        settingsStore: any SettingsStoreProtocol = MockSettingsStore(),
        pathDetectionService: any PathDetectionServiceProtocol = MockPathDetectionService(),
        updateService: any UpdateServiceProtocol = MockUpdateService(),
        translationService: any TranslationUpdateServiceProtocol = MockTranslationUpdateService(),
        rjwOperationService: any RJWOperationServiceProtocol = MockRJWOperationService(),
        rjwCatalogService: any RJWCatalogServiceProtocol = MockRJWCatalogService()
    ) -> ApplicationModel {
        let model = ApplicationModel(
            settingsStore: settingsStore,
            pathDetectionService: pathDetectionService,
            updateService: updateService,
            translationService: translationService,
            rjwOperationService: rjwOperationService,
            rjwCatalogService: rjwCatalogService
        )
        model.language = .english
        model.resetLocalizedText()
        return model
    }

    @MainActor private func makeTranslationModel(service: MockTranslationUpdateService) throws -> ApplicationModel {
        let game = try createDirectory("RimWorldMac.app")
        _ = try createDirectory("RimWorldMac.app/Data/Core/Languages")
        let mods = try createDirectory("RimWorldMac.app/Mods")
        let model = makeModel(translationService: service)
        model.settingsState.modURLs = [mods]
        XCTAssertEqual(model.rimWorldApplication(), game)
        return model
    }

    @MainActor private func makeRJWModel(
        service: MockRJWOperationService,
        catalogService: MockRJWCatalogService = MockRJWCatalogService()
    ) throws -> (ApplicationModel, URL, RJWProvider) {
        _ = try createDirectory("RimWorldMac.app")
        _ = try createDirectory("RimWorldMac.app/Data/Core/Languages")
        let mods = try createDirectory("RimWorldMac.app/Mods")
        let model = makeModel(rjwOperationService: service, rjwCatalogService: catalogService)
        model.settingsState.modURLs = [mods]
        let provider = try makeProvider()
        model.rjwProviders = [(category: "Tests", provider: provider)]
        model.selectedRJWProviderNames = [provider.name]
        return (model, mods, provider)
    }

    private func makeProvider() throws -> RJWProvider {
        try JSONDecoder().decode(RJWProvider.self, from: Data(#"""
        {
            "type": "git",
            "name": "TestProvider",
            "description": "Test provider",
            "url": "https://example.com/test.git"
        }
        """#.utf8))
    }

    private func createDirectory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createFile(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
        return url
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func waitForAsyncModelUpdates() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    @MainActor private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

private enum TestError: LocalizedError {
    case failure

    var errorDescription: String? { "Injected test failure" }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("MockURLProtocol request handler is missing")
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
