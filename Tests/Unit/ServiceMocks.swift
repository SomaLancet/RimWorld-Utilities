import Foundation
@testable import RimWorld_Utilities

final class MockTranslationUpdateService: TranslationUpdateServiceProtocol {
    private(set) var isRunning = false
    private(set) var startCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var gameURL: URL?
    private var continuation: AsyncThrowingStream<OperationProgress, Error>.Continuation?

    func updates(gameURL: URL) -> AsyncThrowingStream<OperationProgress, Error> {
        startCallCount += 1
        isRunning = true
        self.gameURL = gameURL
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        cancelCallCount += 1
    }

    @MainActor func sendProgress(_ progress: OperationProgress) {
        continuation?.yield(progress)
    }

    @MainActor func complete(with result: Result<Void, Error>) {
        isRunning = false
        let continuation = continuation
        self.continuation = nil
        switch result {
        case .success:
            continuation?.finish()
        case .failure(let error):
            continuation?.finish(throwing: error)
        }
    }
}

final class MockRJWOperationService: RJWOperationServiceProtocol {
    private(set) var isRunning = false
    private(set) var startCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var operations: [RJWOperation] = []
    private(set) var modsURL: URL?
    private var continuation: AsyncThrowingStream<OperationProgress, Error>.Continuation?

    func updates(operations: [RJWOperation], modsURL: URL) -> AsyncThrowingStream<OperationProgress, Error> {
        startCallCount += 1
        isRunning = true
        self.operations = operations
        self.modsURL = modsURL
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        cancelCallCount += 1
    }

    @MainActor func sendProgress(_ progress: OperationProgress) {
        continuation?.yield(progress)
    }

    @MainActor func complete(with result: Result<Void, Error>) {
        isRunning = false
        let continuation = continuation
        self.continuation = nil
        switch result {
        case .success:
            continuation?.finish()
        case .failure(let error):
            continuation?.finish(throwing: error)
        }
    }
}

final class MockRJWCatalogService: RJWCatalogServiceProtocol, @unchecked Sendable {
    private(set) var loadCallCount = 0
    private var continuation: CheckedContinuation<[RJWCatalogItem], Error>?

    func load() async throws -> [RJWCatalogItem] {
        loadCallCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    @MainActor func complete(with result: Result<[RJWCatalogItem], Error>) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

final class MockUpdateService: UpdateServiceProtocol {
    private(set) var requestedVersions: [String] = []
    var result: Result<GitHubRelease?, Error> = .success(nil)

    func latestRelease(currentVersion: String) async throws -> GitHubRelease? {
        requestedVersions.append(currentVersion)
        return try result.get()
    }
}

final class MockPathDetectionService: PathDetectionServiceProtocol {
    var rimWorldDataDirectories: [URL] = []
    var preferredDataDirectory = URL(fileURLWithPath: "/", isDirectory: true)
    var workshopModDirectories: [URL] = []
    var localModDirectories: [URL] = []
    var modDirectories: [URL]?
    var saveURL: URL?
    var configURL: URL?
    var logURL: URL?

    func detectedWorkshopModDirectories() -> [URL] { workshopModDirectories }
    func detectedLocalModDirectories() -> [URL] { localModDirectories }
    func detectedModDirectories() -> [URL] { modDirectories ?? localModDirectories + workshopModDirectories }
    func latestSave() -> URL? { saveURL }
    func detectedConfig() -> URL? { configURL }
    func detectedLog() -> URL? { logURL }
}

final class MockSettingsStore: SettingsStoreProtocol {
    var loadedSettings: AppSettings?
    var saveError: Error?
    private(set) var savedSettings: [AppSettings] = []

    func load() -> AppSettings? { loadedSettings }

    func save(_ settings: AppSettings) throws {
        if let saveError { throw saveError }
        savedSettings.append(settings)
    }
}
