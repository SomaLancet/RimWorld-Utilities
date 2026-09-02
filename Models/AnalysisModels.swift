import Foundation

struct ModInfo: Codable, Hashable {
    let packageId: String
    let name: String?
    let path: String?
}

struct LogIssue: Codable {
    let category: String
    let severity: String
    let message: String
    var count: Int
    let relatedMods: [ModInfo]
    let confidence: String?
    let evidence: String?
}

struct SaveFinding: Codable {
    let kind: String
    let value: String
    let count: Int
    let relatedMod: ModInfo?
    let confidence: String
    let evidence: String
}

struct StructuralIssue: Codable {
    let objectId: String
    let objectName: String
    let objectType: String
    let field: String
    let problem: String
    let level: String
}

struct AnalysisReport: Codable {
    let savePath: String
    let gameVersion: String?
    let saveMods: [ModInfo]
    let installedMods: [ModInfo]
    let activeModIds: [String]
    let missingMods: [ModInfo]
    let installedNotInSave: [ModInfo]
    let activeNotInSave: [String]
    let saveNotActive: [ModInfo]
    let loadOrderChanged: Bool?
    let logIssues: [LogIssue]
    let saveFindings: [SaveFinding]
    let structuralIssues: [StructuralIssue]
    let scannedClassReferences: Int
    let scannedDefReferences: Int
    let scannedPawns: Int
    let notes: [String]
}

struct ModRemovalPlanItem: Identifiable, Codable {
    let category: String
    let subject: String
    let count: Int
    let action: String

    var id: String { [category, subject, action].joined(separator: "|") }
}

struct ModRemovalPreviewItem: Identifiable, Codable {
    let entity: String
    let subject: String
    let action: String
    let replacement: String?
    let sourceModName: String?
    let sourceModVersion: String?
    let count: Int

    var id: String { [entity, subject, action, replacement ?? "", sourceModName ?? "", sourceModVersion ?? ""].joined(separator: "|") }
}

struct ModRemovalReport: Codable {
    let savePath: String
    let modPath: String
    var modPaths: [String]? = nil
    let packageId: String?
    var packageIds: [String]? = nil
    let modName: String?
    var modNames: [String]? = nil
    let defCount: Int
    let matchedDefCount: Int
    let foreignReferenceCount: Int
    let planItems: [ModRemovalPlanItem]
    var previewItems: [ModRemovalPreviewItem]? = nil
    let backupPath: String?
    let outputPath: String?

    var summaryLines: [String] {
        [
            "Save: \(savePath)",
            "Mod: \(modNames?.joined(separator: ", ") ?? modName ?? packageId ?? modPath)",
            "Defs indexed: \(defCount)",
            "Defs referenced by save: \(matchedDefCount)",
            "Foreign references ignored: \(foreignReferenceCount)"
        ] + planItems.map { "\($0.category): \($0.subject) - \($0.action) (\($0.count))" }
    }
}

struct SaveCleanerPreviewItem: Identifiable, Codable {
    let entity: String
    let subject: String
    let action: String
    let replacement: String?
    let confidence: String
    let count: Int

    var id: String { [entity, subject, action, replacement ?? "", confidence].joined(separator: "|") }
}

struct SaveCleanerReport: Codable {
    let savePath: String
    let activeDefCount: Int
    let scannedModCount: Int
    let unknownDefCount: Int
    let previewItems: [SaveCleanerPreviewItem]
    let outputPath: String?

    var changeCount: Int {
        previewItems.reduce(0) { $0 + $1.count }
    }
}

struct ModRemovalCandidate: Identifiable, Hashable {
    let url: URL
    let name: String?
    let packageId: String?
    let source: String

    var id: String { url.path }
    var displayName: String { name ?? packageId ?? url.lastPathComponent }
    var isOfficialContent: Bool { packageId?.lowercased().hasPrefix("ludeon.rimworld") == true }
    var searchText: String {
        [name, packageId, url.lastPathComponent, source]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }
}

struct SaveCandidate: Identifiable, Hashable {
    let url: URL
    let modifiedAt: Date

    var id: String { url.path }
    var displayName: String { url.deletingPathExtension().lastPathComponent }
}

enum AnalyzerError: LocalizedError {
    case invalidSave

    var errorDescription: String? {
        switch self {
        case .invalidSave:
            return "В файле нет секции <meta>. Похоже, это не сохранение RimWorld."
        }
    }
}
