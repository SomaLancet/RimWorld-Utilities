import Foundation

protocol UpdateServiceProtocol: AnyObject {
    func latestRelease(currentVersion: String) async throws -> GitHubRelease?
}

final class UpdateService: UpdateServiceProtocol {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func latestRelease(currentVersion: String) async throws -> GitHubRelease? {
        guard let url = URL(string: "https://api.github.com/repos/SomaLancet/RimWorld-Utilities/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("RimWorld-Utilities/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
            return nil
        }
        let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return latest.compare(currentVersion, options: .numeric) == .orderedDescending ? release : nil
    }
}
