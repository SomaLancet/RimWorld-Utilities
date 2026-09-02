import Foundation

protocol PathDetectionServiceProtocol: AnyObject {
    var rimWorldDataDirectories: [URL] { get }
    var preferredDataDirectory: URL { get }

    func detectedWorkshopModDirectories() -> [URL]
    func detectedLocalModDirectories() -> [URL]
    func detectedModDirectories() -> [URL]
    func latestSave() -> URL?
    func detectedConfig() -> URL?
    func detectedLog() -> URL?
}

final class PathDetectionService: PathDetectionServiceProtocol {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var rimWorldDataDirectories: [URL] {
        let support = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return existing([
            support.appendingPathComponent("RimWorld", isDirectory: true),
            support.appendingPathComponent("RimWorld by Ludeon Studios", isDirectory: true),
            support.appendingPathComponent("ludeon.rimworld", isDirectory: true)
        ], directory: true)
    }

    var preferredDataDirectory: URL {
        rimWorldDataDirectories.first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RimWorld", isDirectory: true)
    }

    func detectedWorkshopModDirectories() -> [URL] {
        existing(steamLibraries().map {
            $0.appendingPathComponent("steamapps/workshop/content/294100", isDirectory: true)
        }, directory: true)
    }

    func detectedLocalModDirectories() -> [URL] {
        var candidates: [URL] = []
        for library in steamLibraries() {
            let app = library.appendingPathComponent("steamapps/common/RimWorld/RimWorldMac.app", isDirectory: true)
            candidates.append(app.appendingPathComponent("Mods", isDirectory: true))
            candidates.append(app.appendingPathComponent("Data", isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: "/Applications/RimWorld/RimWorldMac.app/Mods", isDirectory: true))
        candidates.append(URL(fileURLWithPath: "/Applications/RimWorld/RimWorldMac.app/Data", isDirectory: true))
        var seen: Set<String> = []
        return existing(candidates, directory: true).filter {
            seen.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted
        }
    }

    func detectedModDirectories() -> [URL] {
        detectedLocalModDirectories() + detectedWorkshopModDirectories()
    }

    func latestSave() -> URL? {
        let files = rimWorldDataDirectories.flatMap { directory -> [URL] in
            let saves = directory.appendingPathComponent("Saves", isDirectory: true)
            return (try? fileManager.contentsOfDirectory(
                at: saves,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }
        return files.filter { $0.pathExtension.lowercased() == "rws" }.max { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate < rightDate
        }
    }

    func detectedConfig() -> URL? {
        existing(
            rimWorldDataDirectories.map { $0.appendingPathComponent("Config/ModsConfig.xml") },
            directory: false
        ).first
    }

    func detectedLog() -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Logs/Ludeon Studios/RimWorld by Ludeon Studios/Player.log"),
            home.appendingPathComponent("Library/Logs/Unity/Player.log")
        ] + rimWorldDataDirectories.map { $0.appendingPathComponent("Player.log") }
        return existing(candidates, directory: false).first
    }

    private func existing(_ urls: [URL], directory: Bool? = nil) -> [URL] {
        urls.filter { url in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
            return directory == nil || isDirectory.boolValue == directory
        }
    }

    private func steamLibraries() -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        let defaultSteam = home.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
        var roots = [defaultSteam]
        let libraryFile = defaultSteam.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let contents = try? String(contentsOf: libraryFile, encoding: .utf8),
           let regex = try? NSRegularExpression(pattern: #""path"\s+"([^"]+)""#) {
            let range = NSRange(contents.startIndex..., in: contents)
            for match in regex.matches(in: contents, range: range) {
                guard match.numberOfRanges > 1,
                      let valueRange = Range(match.range(at: 1), in: contents) else { continue }
                let path = String(contents[valueRange]).replacingOccurrences(of: #"\\"#, with: #"\"#)
                roots.append(URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        var seen: Set<String> = []
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
