import Foundation
import OSLog

protocol ModRemovalServiceProtocol: AnyObject, Sendable {
    func scanAsync(saveURL: URL, modURLs: [URL], removeMetadata: Bool, protectedModURLs: [URL]) async throws -> ModRemovalReport
    func cleanAsync(saveURL: URL, modURLs: [URL], mode: ModRemovalMode, removeMetadata: Bool, protectedModURLs: [URL]) async throws -> ModRemovalReport
    func findCandidatesAsync(in roots: [URL], includeOfficial: Bool) async -> [ModRemovalCandidate]
    func activeProtectionURLsAsync(configURL: URL?, modURLs: [URL], selectedModURLs: [URL]) async -> [URL]
}

enum ModRemovalMode {
    case conservative
}

enum ModRemovalError: LocalizedError {
    case invalidModFolder
    case invalidSave
    case writeFailed
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidModFolder:
            return "Папка мода не содержит About/About.xml или Defs."
        case .invalidSave:
            return "Файл не похож на сохранение RimWorld."
        case .writeFailed:
            return "Не удалось записать очищенное сохранение."
        case .validationFailed(let details):
            return "Очищенная копия не прошла проверку: \(details)"
        }
    }
}

final class ModRemovalService: ModRemovalServiceProtocol, Sendable {
    private static let logger = Logger(subsystem: "local.rimworld.utilities", category: "ModRemoval")

    private struct DefSource {
        let name: String?
        let version: String?
        let path: String?
        let origin: String?
    }

    private struct WorkTypeSource {
        let defName: String
        let path: String
        let isPatch: Bool
    }

    private struct ModScan {
        var path: String?
        var packageId: String?
        var name: String?
        var version: String?
        var packageIds: Set<String> = []
        var names: Set<String> = []
        var paths: [String] = []
        var defs: Set<String> = []
        var defsByKind: [String: Set<String>] = [:]
        var defSources: [String: DefSource] = [:]
        var foreignReferences: Set<String> = []
        var classNames: Set<String> = []
        var workTypeSources: [WorkTypeSource] = []

        var factionDefs: Set<String> { defsByKind["FactionDef"] ?? [] }
        var pawnKindDefs: Set<String> { defsByKind["PawnKindDef"] ?? [] }
        var geneDefs: Set<String> { defsByKind["GeneDef"] ?? [] }
        var xenotypeDefs: Set<String> { defsByKind["XenotypeDef"] ?? [] }
        var itemDefs: Set<String> {
            var result = Set<String>()
            for key in ["ThingDef", "ThingDef ParentName=\"BaseWeapon\"", "ThingDef ParentName=\"BaseHumanMakeableGun\""] {
                result.formUnion(defsByKind[key] ?? [])
            }
            result.formUnion(defs.filter { $0.hasPrefix("Techprint_") })
            return result
        }
    }

    func scanAsync(saveURL: URL, modURLs: [URL], removeMetadata: Bool = false, protectedModURLs: [URL] = []) async throws -> ModRemovalReport {
        try await Task.detached(priority: .userInitiated) {
            try self.scan(saveURL: saveURL, modURLs: modURLs, removeMetadata: removeMetadata, protectedModURLs: protectedModURLs)
        }.value
    }

    func cleanAsync(saveURL: URL, modURLs: [URL], mode: ModRemovalMode = .conservative, removeMetadata: Bool = false, protectedModURLs: [URL] = []) async throws -> ModRemovalReport {
        try await Task.detached(priority: .userInitiated) {
            try self.clean(saveURL: saveURL, modURLs: modURLs, mode: mode, removeMetadata: removeMetadata, protectedModURLs: protectedModURLs)
        }.value
    }

    static func findCandidatesAsync(in roots: [URL], includeOfficial: Bool = false) async -> [ModRemovalCandidate] {
        await Task.detached(priority: .userInitiated) {
            findCandidates(in: roots, includeOfficial: includeOfficial)
        }.value
    }

    func findCandidatesAsync(in roots: [URL], includeOfficial: Bool = false) async -> [ModRemovalCandidate] {
        await Self.findCandidatesAsync(in: roots, includeOfficial: includeOfficial)
    }

    static func activeProtectionURLsAsync(configURL: URL?, modURLs: [URL], selectedModURLs: [URL]) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            activeProtectionURLs(configURL: configURL, modURLs: modURLs, selectedModURLs: selectedModURLs)
        }.value
    }

    func activeProtectionURLsAsync(configURL: URL?, modURLs: [URL], selectedModURLs: [URL]) async -> [URL] {
        await Self.activeProtectionURLsAsync(configURL: configURL, modURLs: modURLs, selectedModURLs: selectedModURLs)
    }

    static func activeProtectionURLs(configURL: URL?, modURLs: [URL], selectedModURLs: [URL]) -> [URL] {
        var protectionRoots = modURLs
        for root in modURLs where root.lastPathComponent.caseInsensitiveCompare("Mods") == .orderedSame {
            let dataURL = root.deletingLastPathComponent().appendingPathComponent("Data", isDirectory: true)
            if FileManager.default.fileExists(atPath: dataURL.path) {
                protectionRoots.append(dataURL)
            }
        }

        let activePackageIds: Set<String>
        if let configURL, let xml = try? XMLValues.read(configURL) {
            activePackageIds = Set(xml.list("/ModsConfigData/activeMods/li").map { $0.lowercased() })
        } else {
            activePackageIds = []
        }
        let selectedPaths = Set(selectedModURLs.map { $0.standardizedFileURL.path })
        let candidates = findCandidates(in: protectionRoots, includeOfficial: true)
        let protectedURLs: [URL] = candidates.compactMap { candidate -> URL? in
            guard !selectedPaths.contains(candidate.url.standardizedFileURL.path) else { return nil }
            if candidate.isOfficialContent { return candidate.url }
            guard let packageId = candidate.packageId?.lowercased(), activePackageIds.contains(packageId) else { return nil }
            return candidate.url
        }
        logger.notice("Protection roots: \(protectionRoots.map(\.path).joined(separator: " | "), privacy: .public)")
        logger.notice("Selected mod paths: \(selectedModURLs.map(\.path).joined(separator: " | "), privacy: .public)")
        logger.notice("Protected mod paths: \(protectedURLs.map(\.path).joined(separator: " | "), privacy: .public)")
        logger.notice("Protection candidates: \(candidates.count, privacy: .public); active package IDs: \(activePackageIds.count, privacy: .public)")
        return protectedURLs
    }

    static func findCandidates(in roots: [URL], includeOfficial: Bool = false) -> [ModRemovalCandidate] {
        let fileManager = FileManager.default
        var seenPaths: Set<String> = []
        var candidates: [ModRemovalCandidate] = []

        for root in roots {
            let standardizedRoot = root.standardizedFileURL
            let scanURLs = candidateModFolders(under: standardizedRoot, fileManager: fileManager)
            for url in scanURLs {
                let path = url.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else { continue }
                guard let candidate = readCandidate(at: url, source: standardizedRoot.lastPathComponent, includeOfficial: includeOfficial) else { continue }
                candidates.append(candidate)
            }
        }

        return candidates.sorted {
            let nameOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    private static func candidateModFolders(under root: URL, fileManager: FileManager) -> [URL] {
        var urls: [URL] = [root]
        let children = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
        urls.append(contentsOf: children.filter { child in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory) && isDirectory.boolValue
        })
        return urls
    }

    private static func readCandidate(at url: URL, source: String, includeOfficial: Bool = false) -> ModRemovalCandidate? {
        let aboutURLs = [
            url.appendingPathComponent("About/About.xml"),
            url.appendingPathComponent("About/about.xml")
        ]
        guard let aboutURL = aboutURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let xml = try? XMLValues.read(aboutURL) else {
            return nil
        }
        let name = xml.firstModMetadataValue("name")
        let packageId = xml.firstModMetadataValue("packageId")
        guard name != nil || packageId != nil else { return nil }
        let candidate = ModRemovalCandidate(url: url, name: name, packageId: packageId, source: source)
        return !includeOfficial && candidate.isOfficialContent ? nil : candidate
    }

    func scan(saveURL: URL, modURL: URL, removeMetadata: Bool = false, protectedModURLs: [URL] = []) throws -> ModRemovalReport {
        try scan(saveURL: saveURL, modURLs: [modURL], removeMetadata: removeMetadata, protectedModURLs: protectedModURLs)
    }

    func scan(saveURL: URL, modURLs: [URL], removeMetadata: Bool = false, protectedModURLs: [URL] = []) throws -> ModRemovalReport {
        let scans = try modURLs.map { try scanMod(at: $0) }
        let protectedScans = try protectedModURLs.map { try scanMod(at: $0) }
        let protectedScan = combinedScan(from: protectedScans)
        let mod = removingProtectedSymbols(from: combinedScan(from: scans), protectedScan: protectedScan)
        guard !mod.defs.isEmpty || !mod.classNames.isEmpty || mod.packageId != nil else { throw ModRemovalError.invalidModFolder }
        let references = try SaveReferenceReader.read(saveURL)
        let matched = mod.defs.filter { references.defs[$0] != nil }
        Self.logger.notice("Scanning save: \(saveURL.path, privacy: .public)")
        Self.logger.notice("Selected definitions after protection: \(mod.defs.count, privacy: .public); protected definitions: \(protectedScan.defs.count, privacy: .public); matched: \(matched.count, privacy: .public)")
        for def in matched.sorted() {
            let source = mod.defSources[def]
            Self.logger.notice("Matched def \(def, privacy: .public); mod=\(source?.name ?? "unknown", privacy: .public); origin=\(source?.origin ?? "unknown", privacy: .public); file=\(source?.path ?? "unknown", privacy: .public)")
        }
        let workTypeIndices = try removedWorkTypeIndices(
            saveURL: saveURL,
            removedScans: scans,
            protectedScans: protectedScans
        )
        let plan = makePlan(
            mod: mod,
            references: references,
            removeMetadata: removeMetadata,
            removedWorkTypeCount: workTypeIndices.count
        )
        let preview = try makePreview(
            saveURL: saveURL,
            mod: mod,
            removeMetadata: removeMetadata,
            removedWorkTypeIndices: workTypeIndices
        )
        return ModRemovalReport(
            savePath: saveURL.path,
            modPath: modURLs.first?.path ?? "",
            modPaths: mod.paths,
            packageId: mod.packageId,
            packageIds: Array(mod.packageIds).sorted(),
            modName: mod.name,
            modNames: Array(mod.names).sorted(),
            defCount: mod.defs.count,
            matchedDefCount: matched.count,
            foreignReferenceCount: mod.foreignReferences.count,
            planItems: plan,
            previewItems: preview,
            backupPath: nil,
            outputPath: nil
        )
    }

    func clean(saveURL: URL, modURL: URL, mode: ModRemovalMode = .conservative, removeMetadata: Bool = false, protectedModURLs: [URL] = []) throws -> ModRemovalReport {
        try clean(saveURL: saveURL, modURLs: [modURL], mode: mode, removeMetadata: removeMetadata, protectedModURLs: protectedModURLs)
    }

    func clean(saveURL: URL, modURLs: [URL], mode: ModRemovalMode = .conservative, removeMetadata: Bool = false, protectedModURLs: [URL] = []) throws -> ModRemovalReport {
        let scanReport = try scan(saveURL: saveURL, modURLs: modURLs, removeMetadata: removeMetadata, protectedModURLs: protectedModURLs)
        let removedScans = try modURLs.map { try scanMod(at: $0) }
        let protectedScans = try protectedModURLs.map { try scanMod(at: $0) }
        let protectedScan = combinedScan(from: protectedScans)
        let mod = removingProtectedSymbols(
            from: combinedScan(from: removedScans),
            protectedScan: protectedScan
        )
        let outputURL = cleanedURL(for: saveURL)

        let options: XMLNode.Options = [.nodePreserveWhitespace]
        let document = try XMLDocument(contentsOf: saveURL, options: options)
        guard let root = document.rootElement(), root.name == "savegame" else {
            throw ModRemovalError.invalidSave
        }

        var stats: [String: Int] = [:]
        func increment(_ key: String, by count: Int = 1) { stats[key, default: 0] += count }
        let initialElements = allElements(root)
        let initialDictionaryMismatches = parallelDictionaryMismatchCount(in: initialElements)
        let initialDuplicateIDs = duplicateObjectIDs(in: initialElements)
        let initialInvalidBodyPartReferences = invalidBodyPartReferenceCount(in: initialElements)

        let factionIds = factionLoadIds(in: initialElements, factionDefs: mod.factionDefs)

        if removeMetadata {
            pruneModMetadata(in: root, mod: mod) { increment("Mod metadata entries", by: $0) }
        }

        let workTypeIndices = removedWorkTypeIndices(
            in: root,
            removedScans: removedScans,
            protectedScans: protectedScans
        )
        pruneWorkPriorities(in: root, indices: workTypeIndices) {
            increment("Pawn work priorities", by: $0)
        }

        pruneParallelDictionaries(in: root, badKeys: mod.defs.union(factionIds)) { increment("Dictionary entries", by: $0) }

        for element in allElements(root) where element.name == "li" && mod.factionDefs.contains(element.directText("def")) {
            if detachPreservingParallelDictionary(element) {
                increment("Faction records")
            }
        }

        for element in allElements(root) where element.name == "li" {
            let className = element.attribute(forName: "Class")?.stringValue ?? ""
            if ["Settlement", "Site", "Caravan", "TravelingTransportPods"].contains(className),
               factionIds.contains(element.directText("faction")) {
                if detachPreservingParallelDictionary(element) {
                    increment("World objects")
                }
            }
        }

        for element in allElements(root) where element.name == "li" && factionIds.contains(element.directText("other")) {
            if element.parent?.name == "relations" {
                if detachPreservingParallelDictionary(element) {
                    increment("Faction relations")
                }
            }
        }

        for element in allElements(root) where ["faction", "homeFaction", "hostFaction", "slaveFaction"].contains(element.name ?? "") {
            if let value = element.trimmedText, factionIds.contains(value) {
                element.setStringValue("null", resolvingEntities: false)
                increment("Faction refs nulled")
            }
        }

        var removedObjectIDs = removeAffectedAnimalPawns(in: root, mod: mod) { key in increment(key) }
        scrubPawns(in: root, mod: mod) { key in increment(key) }
        removedObjectIDs.formUnion(clearRemovedCurrentJobs(in: root, mod: mod) { key in increment(key) })
        removedObjectIDs.formUnion(pruneOwnedClassNodes(in: root, mod: mod) { key in increment(key) })

        let removableDefs = mod.defs.subtracting(mod.factionDefs)
        var removedContentNodes = Set<ObjectIdentifier>()
        for element in allElements(root) {
            guard ["li", "thing"].contains(element.name ?? "") else { continue }
            if element.directText("def") == "Human" { continue }
            if shouldRemoveContentNode(element, mod: mod, removableDefs: removableDefs) {
                let target = contentRemovalTarget(for: element)
                let identifier = ObjectIdentifier(target)
                guard !removedContentNodes.contains(identifier) else { continue }
                removedContentNodes.insert(identifier)
                if detachPreservingParallelDictionary(target) {
                    removedObjectIDs.formUnion(objectIDs(in: target))
                    increment("Content nodes")
                }
            }
        }

        for element in allElements(root) where element.name == "li" && element.childrenElements.isEmpty {
            guard let value = element.trimmedText else { continue }
            if mod.defs.contains(value) || factionIds.contains(value) {
                if detachPreservingParallelDictionary(element) {
                    increment("Simple list refs")
                }
            }
        }

        for element in allElements(root) {
            guard let name = element.name, let value = element.trimmedText else { continue }
            if ["xenotype", "originalXenotypeDef"].contains(name), mod.xenotypeDefs.contains(value) {
                element.setStringValue("Baseline", resolvingEntities: false)
                increment("Xenotype refs replaced")
            } else if name == "stuff", mod.defs.contains(value) {
                element.setStringValue("Cloth", resolvingEntities: false)
                increment("Stuff refs replaced")
            } else if name == "kindDef", mod.pawnKindDefs.contains(value) {
                element.setStringValue("Colonist", resolvingEntities: false)
                increment("Pawn kind refs replaced")
            } else if ["peq", "thingDef", "source"].contains(name), mod.defs.contains(value) {
                element.setStringValue("null", resolvingEntities: false)
                increment("Scalar refs nulled")
            }
        }

        removedObjectIDs.formUnion(pruneOwnedDefReferences(in: root, mod: mod) { key in increment(key) })
        pruneReferences(to: removedObjectIDs, in: root) { increment("Dangling object references", by: $0) }

        let finalElements = allElements(root)
        let remainingClasses = finalElements.compactMap {
            $0.attribute(forName: "Class")?.stringValue
        }.filter(mod.classNames.contains)
        let remainingDefs = finalElements.compactMap { element -> String? in
            guard element.childrenElements.isEmpty, let value = element.trimmedText, mod.defs.contains(value) else { return nil }
            return value
        }
        guard remainingClasses.isEmpty, remainingDefs.isEmpty else {
            throw ModRemovalError.validationFailed(
                "остались классы: \(Set(remainingClasses).count), Def-ссылки: \(Set(remainingDefs).count)"
            )
        }
        guard parallelDictionaryMismatchCount(in: finalElements) <= initialDictionaryMismatches else {
            throw ModRemovalError.validationFailed("нарушена структура словаря keys/values")
        }
        guard invalidBodyPartReferenceCount(in: finalElements) <= initialInvalidBodyPartReferences else {
            throw ModRemovalError.validationFailed("повреждены ссылки part/body/index на части тела")
        }
        let remainingDuplicateIDs = duplicateObjectIDs(in: finalElements)
        guard remainingDuplicateIDs.count <= initialDuplicateIDs.count else {
            throw ModRemovalError.validationFailed("появились новые повторяющиеся ID")
        }
        if !remainingDuplicateIDs.isEmpty {
            increment("Pre-existing duplicate IDs requiring review", by: remainingDuplicateIDs.count)
        }

        let data = document.xmlData(options: [])
        guard !data.isEmpty else { throw ModRemovalError.writeFailed }
        guard let validatedDocument = try? XMLDocument(data: data, options: []),
              validatedDocument.rootElement()?.name == "savegame" else {
            throw ModRemovalError.validationFailed("результат не является корректным XML-сохранением")
        }
        try data.write(to: outputURL, options: .atomic)

        let cleanPlan = stats.sorted { $0.key < $1.key }.map {
            let requiresReview = $0.key == "Pre-existing duplicate IDs requiring review"
            return ModRemovalPlanItem(
                category: requiresReview ? "Review" : "Applied",
                subject: $0.key,
                count: $0.value,
                action: requiresReview ? "not changed" : "cleaned"
            )
        }
        return ModRemovalReport(
            savePath: scanReport.savePath,
            modPath: scanReport.modPath,
            modPaths: scanReport.modPaths,
            packageId: scanReport.packageId,
            packageIds: scanReport.packageIds,
            modName: scanReport.modName,
            modNames: scanReport.modNames,
            defCount: scanReport.defCount,
            matchedDefCount: scanReport.matchedDefCount,
            foreignReferenceCount: scanReport.foreignReferenceCount,
            planItems: cleanPlan,
            previewItems: scanReport.previewItems,
            backupPath: nil,
            outputPath: outputURL.path
        )
    }

    private func combinedScan(from scans: [ModScan]) -> ModScan {
        var result = ModScan()
        result.path = scans.first?.path
        result.packageId = scans.first?.packageId
        result.name = scans.first?.name
        result.version = scans.first?.version
        for scan in scans {
            if let path = scan.path { result.paths.append(path) }
            if let packageId = scan.packageId { result.packageIds.insert(packageId) }
            if let name = scan.name { result.names.insert(name) }
            result.defs.formUnion(scan.defs)
            result.foreignReferences.formUnion(scan.foreignReferences)
            result.classNames.formUnion(scan.classNames)
            for (def, source) in scan.defSources where result.defSources[def] == nil {
                result.defSources[def] = source
            }
            for (kind, defs) in scan.defsByKind {
                result.defsByKind[kind, default: []].formUnion(defs)
            }
            result.workTypeSources.append(contentsOf: scan.workTypeSources)
        }
        result.foreignReferences.subtract(result.defs)
        return result
    }

    private func removingProtectedSymbols(from scan: ModScan, protectedScan: ModScan) -> ModScan {
        guard !protectedScan.defs.isEmpty || !protectedScan.classNames.isEmpty else { return scan }
        var result = scan
        let protectedDefinitions = result.defs.intersection(protectedScan.defs)
        if !protectedDefinitions.isEmpty {
            Self.logger.notice("Definitions removed by protection: \(protectedDefinitions.sorted().joined(separator: ", "), privacy: .public)")
        }
        result.defs.subtract(protectedScan.defs)
        result.foreignReferences.subtract(protectedScan.defs)
        result.classNames.subtract(protectedScan.classNames)
        for key in result.defsByKind.keys {
            result.defsByKind[key]?.subtract(protectedScan.defs)
        }
        for def in protectedScan.defs {
            result.defSources.removeValue(forKey: def)
        }
        result.workTypeSources.removeAll { protectedScan.defs.contains($0.defName) }
        return result
    }

    private func makePlan(
        mod: ModScan,
        references: SaveReferenceReader,
        removeMetadata: Bool,
        removedWorkTypeCount: Int
    ) -> [ModRemovalPlanItem] {
        var items = [ModRemovalPlanItem]()
        let defHits = mod.defs.compactMap { def -> (String, Int)? in
            guard let count = references.defs[def] else { return nil }
            return (def, count)
        }.sorted { $0.0 < $1.0 }

        if removeMetadata, !mod.packageIds.isEmpty {
            items.append(ModRemovalPlanItem(category: "Metadata", subject: "\(mod.packageIds.count) mod entries", count: mod.packageIds.count, action: "remove from save modIds"))
        }
        if !mod.factionDefs.isEmpty {
            items.append(ModRemovalPlanItem(category: "Factions", subject: "\(mod.factionDefs.count) faction defs", count: mod.factionDefs.count, action: "remove faction records, settlements, and relations"))
        }
        if !mod.pawnKindDefs.isEmpty || !mod.xenotypeDefs.isEmpty || !mod.geneDefs.isEmpty {
            let count = mod.pawnKindDefs.count + mod.xenotypeDefs.count + mod.geneDefs.count
            items.append(ModRemovalPlanItem(category: "Pawns", subject: "pawn kinds, xenotypes, genes", count: count, action: "replace with safe vanilla values where possible"))
        }
        if !mod.classNames.isEmpty {
            items.append(ModRemovalPlanItem(
                category: "Owned classes",
                subject: "\(mod.classNames.count) serialized .NET types",
                count: mod.classNames.count,
                action: "remove owned serialized components"
            ))
        }
        if removedWorkTypeCount > 0 {
            items.append(ModRemovalPlanItem(
                category: "Pawn work",
                subject: "\(removedWorkTypeCount) custom work types",
                count: removedWorkTypeCount,
                action: "remove matching priority slots"
            ))
        }
        if !mod.foreignReferences.isEmpty {
            items.append(ModRemovalPlanItem(
                category: "Foreign references",
                subject: "\(mod.foreignReferences.count) referenced values",
                count: mod.foreignReferences.count,
                action: "ignored; references are not ownership"
            ))
        }
        for (def, count) in defHits.prefix(60) {
            items.append(ModRemovalPlanItem(category: "References", subject: def, count: count, action: "remove or replace"))
        }
        if defHits.count > 60 {
            items.append(ModRemovalPlanItem(category: "References", subject: "Additional matched defs", count: defHits.count - 60, action: "included in cleanup"))
        }
        return items
    }

    private func makePreview(
        saveURL: URL,
        mod: ModScan,
        removeMetadata: Bool,
        removedWorkTypeIndices: IndexSet
    ) throws -> [ModRemovalPreviewItem] {
        let document = try XMLDocument(contentsOf: saveURL, options: [.nodePreserveWhitespace])
        guard let root = document.rootElement(), root.name == "savegame" else {
            throw ModRemovalError.invalidSave
        }
        let elements = allElements(root)
        let factionIds = factionLoadIds(in: elements, factionDefs: mod.factionDefs)
        let removableDefs = mod.defs.subtracting(mod.factionDefs)
        var counts: [String: Int] = [:]

        func record(_ entity: String, _ subject: String, _ action: String, replacement: String? = nil, by count: Int = 1) {
            let source = sourceInfo(for: subject, mod: mod)
            let key = [entity, subject, action, replacement ?? "", source.name ?? "", source.version ?? ""].joined(separator: "|")
            counts[key, default: 0] += count
        }

        if removeMetadata {
            previewModMetadata(in: root, mod: mod) { subject, count in
                record("Save mod list entries", subject, "remove", by: count)
            }
        }

        let affectedPriorityLists = workPriorityValueLists(in: elements).filter { values in
            removedWorkTypeIndices.allSatisfy { $0 < values.childrenElements.count }
        }.count
        if affectedPriorityLists > 0 {
            record(
                "Pawn work priorities",
                "\(removedWorkTypeIndices.count) custom work types",
                "remove priority slots",
                by: affectedPriorityLists * removedWorkTypeIndices.count
            )
        }

        previewParallelDictionaries(in: elements, badKeys: mod.defs.union(factionIds)) { subject, count in
            record("Dictionary entries", subject, "remove", by: count)
        }

        for element in elements where element.name == "li" && mod.factionDefs.contains(element.directText("def")) {
            record("Factions", element.directText("def"), "remove")
        }

        for element in elements where element.name == "li" {
            let className = element.attribute(forName: "Class")?.stringValue ?? ""
            if ["Settlement", "Site", "Caravan", "TravelingTransportPods"].contains(className),
               factionIds.contains(element.directText("faction")) {
                record("Settlements and world objects", className.isEmpty ? "World object" : className, "remove")
            }
        }

        for element in elements where element.name == "li" && factionIds.contains(element.directText("other")) {
            if element.parent?.name == "relations" {
                record("Faction relations", element.directText("other"), "remove")
            }
        }

        for element in elements where ["faction", "homeFaction", "hostFaction", "slaveFaction"].contains(element.name ?? "") {
            if let value = element.trimmedText, factionIds.contains(value) {
                record("Faction references", value, "replace", replacement: "null")
            }
        }

        previewPawnChanges(in: elements, mod: mod, record: record)

        for jobs in elements {
            guard let subject = removedCurrentJobSubject(in: jobs, mod: mod) else { continue }
            record("Pawn current jobs", subject, "clear")
        }

        for pawn in elements where isAffectedAnimalPawn(pawn, mod: mod) {
            let kind = pawn.directText("kindDef")
            let def = pawn.directText("def")
            record("Things and items", kind.isEmpty ? def : kind, "remove")
        }

        for element in elements {
            guard let className = element.attribute(forName: "Class")?.stringValue,
                  mod.classNames.contains(className) else { continue }
            guard !isInsideRemovedCurrentJobState(element, mod: mod) else { continue }
            if element.directText("def") == "Human" {
                record("Owned serialized classes", className, "replace", replacement: "Pawn")
            } else {
                record("Owned serialized classes", className, "remove")
            }
        }

        var removedContentNodes = Set<ObjectIdentifier>()
        for element in elements {
            guard ["li", "thing"].contains(element.name ?? "") else { continue }
            if element.directText("def") == "Human" { continue }
            if shouldRemoveContentNode(element, mod: mod, removableDefs: removableDefs) {
                let target = contentRemovalTarget(for: element)
                let identifier = ObjectIdentifier(target)
                guard !removedContentNodes.contains(identifier) else { continue }
                removedContentNodes.insert(identifier)
                let subject = element.directText("def").isEmpty ? element.directText("thingDef") : element.directText("def")
                record("Things and items", subject.isEmpty ? "Saved thing" : subject, "remove")
            }
        }

        for element in elements where element.name == "li" && element.childrenElements.isEmpty {
            guard let value = element.trimmedText else { continue }
            if mod.defs.contains(value) || factionIds.contains(value) {
                record("Simple list references", value, "remove")
            }
        }

        for element in elements {
            guard let name = element.name, let value = element.trimmedText else { continue }
            if ["xenotype", "originalXenotypeDef"].contains(name), mod.xenotypeDefs.contains(value) {
                record("Xenotypes", value, "replace", replacement: "Baseline")
            } else if name == "stuff", mod.defs.contains(value) {
                record("Stuff", value, "replace", replacement: "Cloth")
            } else if name == "kindDef", mod.pawnKindDefs.contains(value) {
                guard !isInsideAffectedAnimalPawn(element, mod: mod) else { continue }
                record("Pawn kinds", value, "replace", replacement: "Colonist")
            } else if ["peq", "thingDef", "source"].contains(name), mod.defs.contains(value) {
                record("Scalar references", "\(name): \(value)", "replace", replacement: "null")
            }
        }


        let specificallyHandledFields: Set<String> = [
            "li", "xenotype", "originalXenotypeDef", "stuff", "kindDef", "peq", "thingDef", "source"
        ]
        for element in elements where element.childrenElements.isEmpty {
            guard let name = element.name,
                  !specificallyHandledFields.contains(name),
                  let value = element.trimmedText,
                  mod.defs.contains(value) else { continue }
            guard !isInsideRemovedCurrentJobState(element, mod: mod) else { continue }
            let action = ["def", "recipe", "recipeDef", "hediffDef", "geneDef", "abilityDef"].contains(name)
                ? "remove containing object"
                : "replace with null"
            record("Owned references", "\(name): \(value)", action)
        }

        return counts.map { key, count in
            let parts = key.components(separatedBy: "|")
            return ModRemovalPreviewItem(
                entity: parts[0],
                subject: parts[1],
                action: parts[2],
                replacement: parts[3].isEmpty ? nil : parts[3],
                sourceModName: parts[4].isEmpty ? nil : parts[4],
                sourceModVersion: parts[5].isEmpty ? nil : parts[5],
                count: count
            )
        }
        .sorted {
            if $0.entity != $1.entity { return $0.entity.localizedCaseInsensitiveCompare($1.entity) == .orderedAscending }
            return $0.subject.localizedCaseInsensitiveCompare($1.subject) == .orderedAscending
        }
    }

    private func previewModMetadata(in root: XMLElement, mod: ModScan, record: (String, Int) -> Void) {
        let idsToRemove = Set(mod.packageIds.map { $0.lowercased() })
        let namesToRemove = Set(mod.names.map { $0.lowercased() })
        guard !idsToRemove.isEmpty || !namesToRemove.isEmpty,
              let meta = root.directElement("meta") else { return }

        if let modIds = meta.directElement("modIds") {
            for item in modIds.childrenElements where item.name == "li" {
                guard let value = item.trimmedText, idsToRemove.contains(value.lowercased()) else { continue }
                record(value, 1)
            }
        }
        if let modNames = meta.directElement("modNames") {
            for item in modNames.childrenElements where item.name == "li" {
                guard let value = item.trimmedText, namesToRemove.contains(value.lowercased()) else { continue }
                record(value, 1)
            }
        }
    }

    private func previewParallelDictionaries(in elements: [XMLElement], badKeys: Set<String>, record: (String, Int) -> Void) {
        for container in elements {
            guard let keys = container.directElement("keys"), let values = container.directElement("values") else { continue }
            let keyItems = keys.childrenElements
            let valueItems = values.childrenElements
            guard keyItems.count == valueItems.count else { continue }
            for item in keyItems {
                guard let key = item.trimmedText, badKeys.contains(key) else { continue }
                record(key, 1)
            }
        }
    }

    private func previewPawnChanges(in elements: [XMLElement], mod: ModScan, record: (String, String, String, String?, Int) -> Void) {
        for pawn in elements where pawn.directText("def") == "Human" {
            if let kind = pawn.directElement("kindDef"), let value = kind.trimmedText, mod.pawnKindDefs.contains(value) {
                record("Pawn kinds", value, "replace", "Colonist", 1)
            }

            guard let genes = pawn.directElement("genes") else { continue }
            var removedGeneIds = Set<String>()
            for listName in ["endogenes", "xenogenes"] {
                guard let geneList = genes.directElement(listName) else { continue }
                for gene in geneList.childrenElements where mod.geneDefs.contains(gene.directText("def")) {
                    let def = gene.directText("def")
                    let loadID = gene.directText("loadID")
                    if !loadID.isEmpty { removedGeneIds.insert("Gene_\(loadID)") }
                    record("Genes", def.isEmpty ? "Gene" : def, "remove", nil, 1)
                }
            }
            for override in allElements(genes) where override.name == "overriddenByGene" {
                if let value = override.trimmedText, removedGeneIds.contains(value) {
                    record("Gene override references", value, "replace", "null", 1)
                }
            }
            if let xenotype = genes.directElement("xenotype"),
               let value = xenotype.trimmedText,
               mod.xenotypeDefs.contains(value) {
                record("Xenotypes", value, "replace", "Baseline", 1)
            }
        }
    }

    private func sourceInfo(for subject: String, mod: ModScan) -> DefSource {
        if let source = mod.defSources[subject] {
            return source
        }
        if let value = subject.components(separatedBy: ": ").last,
           value != subject,
           let source = mod.defSources[value] {
            return source
        }
            return DefSource(name: nil, version: nil, path: nil, origin: nil)
    }

    private func pruneModMetadata(in root: XMLElement, mod: ModScan, record: (Int) -> Void) {
        let idsToRemove = Set(mod.packageIds.map { $0.lowercased() })
        let namesToRemove = Set(mod.names.map { $0.lowercased() })
        guard !idsToRemove.isEmpty || !namesToRemove.isEmpty,
              let meta = root.directElement("meta") else { return }

        var removed = 0
        if let modIds = meta.directElement("modIds") {
            for item in modIds.childrenElements where item.name == "li" {
                guard let value = item.trimmedText?.lowercased(), idsToRemove.contains(value) else { continue }
                item.detach()
                removed += 1
            }
        }
        if let modNames = meta.directElement("modNames") {
            for item in modNames.childrenElements where item.name == "li" {
                guard let value = item.trimmedText?.lowercased(), namesToRemove.contains(value) else { continue }
                item.detach()
                removed += 1
            }
        }
        if removed > 0 {
            record(removed)
        }
    }

    private func scanMod(at url: URL) throws -> ModScan {
        var result = ModScan()
        result.path = url.path
        result.paths = [url.path]
        if let about = firstExistingFile(["About/About.xml", "About/about.xml"], under: url),
           let xml = try? XMLValues.read(about) {
            result.packageId = xml.firstModMetadataValue("packageId")
            result.name = xml.firstModMetadataValue("name")
            result.version = modVersion(from: xml)
            if let packageId = result.packageId { result.packageIds.insert(packageId) }
            if let name = result.name { result.names.insert(name) }
        }

        let xmlFiles = xmlFiles(under: url).sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        let files = xmlFiles.filter { file in
            file.pathComponents.contains { $0.caseInsensitiveCompare("Defs") == .orderedSame }
        }
        for file in files {
            guard let document = try? XMLDocument(contentsOf: file, options: []) else { continue }
            guard let root = document.rootElement(), root.name == "Defs" else { continue }
            for child in root.childrenElements {
                guard let defName = child.directTextOptional("defName") else { continue }
                let kind = child.name ?? "UnknownDef"
                result.defs.insert(defName)
                result.defsByKind[kind, default: []].insert(defName)
                result.defSources[defName] = DefSource(
                    name: result.name ?? result.packageId,
                    version: result.version,
                    path: file.path,
                    origin: "Defs"
                )
                if kind == "WorkTypeDef" {
                    result.workTypeSources.append(WorkTypeSource(
                        defName: defName,
                        path: file.path,
                        isPatch: false
                    ))
                }
            }
            for reference in referencedDefValues(in: root) {
                result.foreignReferences.insert(reference)
            }
        }

        let patchFiles = xmlFiles.filter { file in
            file.pathComponents.contains { $0.caseInsensitiveCompare("Patches") == .orderedSame }
        }
        for file in patchFiles {
            guard let document = try? XMLDocument(contentsOf: file, options: []),
                  let root = document.rootElement() else { continue }
            for (kind, defName) in addedDefs(in: root) {
                result.defs.insert(defName)
                result.defsByKind[kind, default: []].insert(defName)
                result.defSources[defName] = DefSource(
                    name: result.name ?? result.packageId,
                    version: result.version,
                    path: file.path,
                    origin: "PatchOperationAdd"
                )
                if kind == "WorkTypeDef" {
                    result.workTypeSources.append(WorkTypeSource(
                        defName: defName,
                        path: file.path,
                        isPatch: true
                    ))
                }
            }
        }

        for assembly in managedAssemblies(under: url) {
            guard let data = try? Data(contentsOf: assembly) else { continue }
            result.classNames.formUnion(ManagedAssemblyTypeReader.typeNames(in: data))
        }
        result.foreignReferences.subtract(result.defs)
        return result
    }

    private func addedDefs(in root: XMLElement) -> [(String, String)] {
        var result: [(String, String)] = []
        for operation in allElements(root) {
            let operationClass = operation.attribute(forName: "Class")?.stringValue ?? operation.name ?? ""
            guard operationClass.contains("PatchOperation"),
                  operationClass.contains("Add"),
                  let xpath = operation.directTextOptional("xpath"),
                  xpath.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/Defs"),
                  let value = operation.directElement("value") else { continue }
            for candidate in value.childrenElements {
                guard let defName = candidate.directTextOptional("defName") else { continue }
                result.append((candidate.name ?? "UnknownDef", defName))
            }
        }
        return result
    }

    private func managedAssemblies(under url: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            $0.pathExtension.caseInsensitiveCompare("dll") == .orderedSame
                && $0.pathComponents.contains { $0.caseInsensitiveCompare("Assemblies") == .orderedSame }
        }
    }

    private func modVersion(from xml: XMLValues) -> String? {
        let versions = xml.list("/ModMetaData/supportedVersions/li") + xml.list("/ModMetadata/supportedVersions/li")
        if !versions.isEmpty {
            return versions.sorted { $0.localizedStandardCompare($1) == .orderedDescending }.joined(separator: ", ")
        }
        return xml.firstModMetadataValue("targetVersion") ?? xml.firstModMetadataValue("modVersion")
    }

    private func referencedDefValues(in root: XMLElement) -> Set<String> {
        let referenceElementNames: Set<String> = [
            "li", "def", "thingDef", "stuff", "stuffDef", "stuffCategory", "thingClass",
            "thingSetMakerClass", "workerClass", "compClass", "geneClass", "hediffClass",
            "factionDef", "kindDef", "xenotype", "xenotypeDef", "geneDef", "recipeDef",
            "researchPrerequisite", "researchProject", "terrainDef", "pawnKind", "body",
            "bodyPart", "soundDef", "texPath", "graphicPath", "packageId"
        ]
        var result = Set<String>()
        for element in allElements(root) {
            guard let name = element.name, element.childrenElements.isEmpty else { continue }
            if referenceElementNames.contains(name),
               let value = element.trimmedText,
               looksLikeDefReference(value) {
                result.insert(value)
            } else if name != "defName", looksLikeDefReference(name) {
                result.insert(name)
            }
        }
        return result
    }

    private func looksLikeDefReference(_ value: String) -> Bool {
        guard value.count <= 160, !value.contains("\n"), !value.contains(" "), !value.contains("(") else { return false }
        return value.range(of: #"^[A-Za-z][A-Za-z0-9_.\-\/]*$"#, options: .regularExpression) != nil
    }

    private func xmlFiles(under url: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "xml" }
    }

    private func firstExistingFile(_ relativePaths: [String], under root: URL) -> URL? {
        relativePaths.map { root.appendingPathComponent($0) }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private func cleanedURL(for saveURL: URL) -> URL {
        let directory = saveURL.deletingLastPathComponent()
        let fileExtension = saveURL.pathExtension
        let baseName = saveURL.deletingPathExtension().lastPathComponent
        let cleanedName = "\(baseName) [cleaned]"
        return directory
            .appendingPathComponent(cleanedName)
            .appendingPathExtension(fileExtension)
    }

    private func factionLoadIds(in elements: [XMLElement], factionDefs: Set<String>) -> Set<String> {
        var ids = Set<String>()
        for element in elements where element.name == "li" && factionDefs.contains(element.directText("def")) {
            let loadId = element.directText("loadID")
            if !loadId.isEmpty { ids.insert("Faction_\(loadId)") }
        }
        return ids
    }

    private func removedWorkTypeIndices(
        saveURL: URL,
        removedScans: [ModScan],
        protectedScans: [ModScan]
    ) throws -> IndexSet {
        let document = try XMLDocument(contentsOf: saveURL, options: [])
        guard let root = document.rootElement(), root.name == "savegame" else {
            throw ModRemovalError.invalidSave
        }
        return removedWorkTypeIndices(
            in: root,
            removedScans: removedScans,
            protectedScans: protectedScans
        )
    }

    private func removedWorkTypeIndices(
        in root: XMLElement,
        removedScans: [ModScan],
        protectedScans: [ModScan]
    ) -> IndexSet {
        let removedDefs = Set(removedScans.flatMap { $0.workTypeSources.map(\.defName) })
            .subtracting(protectedScans.flatMap { $0.workTypeSources.map(\.defName) })
        guard !removedDefs.isEmpty else { return [] }

        let savePackageIds = root.directElement("meta")?
            .directElement("modIds")?
            .childrenElements
            .compactMap(\.trimmedText)
            .map { $0.lowercased() } ?? []
        var packageOrder: [String: Int] = [:]
        for (index, packageId) in savePackageIds.enumerated() where packageOrder[packageId] == nil {
            packageOrder[packageId] = index
        }
        let gameVersion = root.directElement("meta")?.directTextOptional("gameVersion")
        let scans = (removedScans + protectedScans).enumerated().sorted { left, right in
            let leftOrder = left.element.packageId.flatMap { packageOrder[$0.lowercased()] } ?? Int.max
            let rightOrder = right.element.packageId.flatMap { packageOrder[$0.lowercased()] } ?? Int.max
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            return left.offset < right.offset
        }.map(\.element)

        let compatibleSources = scans.map { scan in
            scan.workTypeSources.filter { source in
                isWorkTypeSource(source, compatibleWith: gameVersion)
            }
        }
        let orderedSources = compatibleSources.flatMap { $0.filter { !$0.isPatch } }
            + compatibleSources.flatMap { $0.filter(\.isPatch) }
        var seen = Set<String>()
        var indices = IndexSet()
        for source in orderedSources where seen.insert(source.defName).inserted {
            let index = seen.count - 1
            if removedDefs.contains(source.defName) {
                indices.insert(index)
            }
        }
        return indices
    }

    private func isWorkTypeSource(_ source: WorkTypeSource, compatibleWith gameVersion: String?) -> Bool {
        guard let gameVersion,
              let targetVersion = majorMinorVersion(in: gameVersion),
              let sourceVersion = URL(fileURLWithPath: source.path).pathComponents
                .compactMap(majorMinorVersion(in:))
                .first else {
            return true
        }
        return sourceVersion == targetVersion
    }

    private func majorMinorVersion(in value: String) -> String? {
        let trimmed = value.lowercased().hasPrefix("v") ? String(value.dropFirst()) : value
        let prefix = trimmed.prefix { $0.isNumber || $0 == "." }
        let components = prefix.split(separator: ".")
        guard components.count >= 2,
              components[0].allSatisfy(\.isNumber),
              components[1].allSatisfy(\.isNumber) else { return nil }
        return "\(components[0]).\(components[1])"
    }

    private func workPriorityValueLists(in elements: [XMLElement]) -> [XMLElement] {
        elements.compactMap { element in
            guard element.name == "workSettings",
                  let priorities = element.directElement("priorities"),
                  let values = priorities.directElement("vals"),
                  values.childrenElements.allSatisfy({ $0.name == "li" }) else { return nil }
            return values
        }
    }

    private func pruneWorkPriorities(in root: XMLElement, indices: IndexSet, record: (Int) -> Void) {
        guard !indices.isEmpty else { return }
        var removed = 0
        for values in workPriorityValueLists(in: allElements(root)) {
            let items = values.childrenElements
            guard indices.allSatisfy({ $0 < items.count }) else { continue }
            for index in indices.reversed() {
                items[index].detach()
                removed += 1
            }
        }
        if removed > 0 { record(removed) }
    }

    private func pruneParallelDictionaries(in root: XMLElement, badKeys: Set<String>, record: (Int) -> Void) {
        for container in allElements(root) {
            guard let keys = container.directElement("keys"), let values = container.directElement("values") else { continue }
            let keyItems = keys.childrenElements
            let valueItems = values.childrenElements
            guard keyItems.count == valueItems.count else { continue }
            var removed = 0
            for index in stride(from: keyItems.count - 1, through: 0, by: -1) {
                guard let key = keyItems[index].trimmedText, badKeys.contains(key) else { continue }
                keyItems[index].detach()
                valueItems[index].detach()
                removed += 1
            }
            if removed > 0 { record(removed) }
        }
    }

    private func parallelDictionaryMismatchCount(in elements: [XMLElement]) -> Int {
        elements.reduce(into: 0) { count, container in
            guard let keys = container.directElement("keys"),
                  let values = container.directElement("values") else { return }
            if keys.childrenElements.count != values.childrenElements.count { count += 1 }
        }
    }

    private func duplicateObjectIDs(in elements: [XMLElement]) -> Set<String> {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for element in elements {
            guard let id = element.directTextOptional("id"), id != "null" else { continue }
            if !seen.insert(id).inserted { duplicates.insert(id) }
        }
        return duplicates
    }

    private func scrubPawns(in root: XMLElement, mod: ModScan, record: (String) -> Void) {
        for pawn in allElements(root) where pawn.directText("def") == "Human" {
            if let kind = pawn.directElement("kindDef"), let value = kind.trimmedText, mod.pawnKindDefs.contains(value) {
                kind.setStringValue("Colonist", resolvingEntities: false)
                record("Pawn kindDefs replaced")
            }

            guard let genes = pawn.directElement("genes") else { continue }
            var removedGeneIds = Set<String>()
            for listName in ["endogenes", "xenogenes"] {
                guard let geneList = genes.directElement(listName) else { continue }
                for gene in geneList.childrenElements where mod.geneDefs.contains(gene.directText("def")) {
                    let loadID = gene.directText("loadID")
                    if detachPreservingParallelDictionary(gene) {
                        if !loadID.isEmpty { removedGeneIds.insert("Gene_\(loadID)") }
                        record("Pawn genes removed")
                    }
                }
            }
            for override in allElements(genes) where override.name == "overriddenByGene" {
                if let value = override.trimmedText, removedGeneIds.contains(value) {
                    override.setStringValue("null", resolvingEntities: false)
                    record("Gene override refs nulled")
                }
            }
            if let xenotype = genes.directElement("xenotype"),
               let value = xenotype.trimmedText,
               mod.xenotypeDefs.contains(value) {
                xenotype.setStringValue("Baseline", resolvingEntities: false)
                record("Pawn xenotypes replaced")
            }
        }
    }

    private func removeAffectedAnimalPawns(
        in root: XMLElement,
        mod: ModScan,
        record: (String) -> Void
    ) -> Set<String> {
        var removedObjectIDs = Set<String>()
        for pawn in allElements(root) where isAffectedAnimalPawn(pawn, mod: mod) {
            if detachPreservingParallelDictionary(pawn) {
                removedObjectIDs.formUnion(objectIDs(in: pawn))
                record("Animal pawns removed")
            }
        }
        return removedObjectIDs
    }

    private func isAffectedAnimalPawn(_ element: XMLElement, mod: ModScan) -> Bool {
        guard element.directText("def") != "Human",
              element.directElement("def") != nil,
              element.directElement("kindDef") != nil,
              element.directElement("id") != nil else {
            return false
        }
        let className = element.attribute(forName: "Class")?.stringValue ?? ""
        guard className.localizedCaseInsensitiveContains("Pawn") else { return false }
        return mod.defs.contains(element.directText("def"))
            || mod.pawnKindDefs.contains(element.directText("kindDef"))
    }

    private func isInsideAffectedAnimalPawn(_ element: XMLElement, mod: ModScan) -> Bool {
        var current: XMLNode? = element
        while let node = current {
            if let candidate = node as? XMLElement,
               isAffectedAnimalPawn(candidate, mod: mod) {
                return true
            }
            current = node.parent
        }
        return false
    }

    private func clearRemovedCurrentJobs(
        in root: XMLElement,
        mod: ModScan,
        record: (String) -> Void
    ) -> Set<String> {
        var removedObjectIDs = Set<String>()
        for jobs in allElements(root) where removedCurrentJobSubject(in: jobs, mod: mod) != nil {
            let currentState = [jobs.directElement("curJob"), jobs.directElement("curDriver")].compactMap { $0 }
            guard !currentState.isEmpty else { continue }
            for element in currentState {
                removedObjectIDs.formUnion(objectIDs(in: element))
                element.detach()
            }
            record("Pawn current jobs cleared")
        }
        return removedObjectIDs
    }

    private func removedCurrentJobSubject(in jobs: XMLElement, mod: ModScan) -> String? {
        guard jobs.name == "jobs" else { return nil }
        let jobDef = jobs.directElement("curJob")?.directText("def") ?? ""
        let driverClass = jobs.directElement("curDriver")?.attribute(forName: "Class")?.stringValue ?? ""
        if !jobDef.isEmpty, mod.defs.contains(jobDef) { return jobDef }
        if !driverClass.isEmpty, mod.classNames.contains(driverClass) { return driverClass }
        return nil
    }

    private func isInsideRemovedCurrentJobState(_ element: XMLElement, mod: ModScan) -> Bool {
        var current: XMLNode? = element
        while let node = current {
            if let candidate = node as? XMLElement,
               removedCurrentJobSubject(in: candidate, mod: mod) != nil {
                return true
            }
            current = node.parent
        }
        return false
    }

    private func pruneOwnedClassNodes(
        in root: XMLElement,
        mod: ModScan,
        record: (String) -> Void
    ) -> Set<String> {
        var removedObjectIDs = Set<String>()
        for element in allElements(root) {
            guard let className = element.attribute(forName: "Class")?.stringValue,
                  mod.classNames.contains(className) else { continue }
            if element.directText("def") == "Human" {
                element.attribute(forName: "Class")?.stringValue = "Pawn"
                record("Owned pawn classes replaced")
                continue
            }
            guard element !== root else { continue }
            if detachPreservingParallelDictionary(element) {
                removedObjectIDs.formUnion(objectIDs(in: element))
                record("Owned class nodes removed")
            }
        }
        return removedObjectIDs
    }

    private func pruneOwnedDefReferences(
        in root: XMLElement,
        mod: ModScan,
        record: (String) -> Void
    ) -> Set<String> {
        let identityFields: Set<String> = [
            "def", "thingDef", "recipe", "recipeDef", "hediffDef", "geneDef",
            "abilityDef", "questScriptDef", "researchProject", "researchPrerequisite"
        ]
        var removedObjectIDs = Set<String>()
        for element in allElements(root) where element.childrenElements.isEmpty {
            guard let name = element.name,
                  let value = element.trimmedText,
                  mod.defs.contains(value) else { continue }

            if name == "li" {
                if detachPreservingParallelDictionary(element) {
                    record("Owned list references removed")
                }
                continue
            }
            if name == "kindDef", mod.pawnKindDefs.contains(value) {
                element.setStringValue("Colonist", resolvingEntities: false)
                record("Pawn kindDefs replaced")
                continue
            }
            if ["xenotype", "originalXenotypeDef"].contains(name), mod.xenotypeDefs.contains(value) {
                element.setStringValue("Baseline", resolvingEntities: false)
                record("Pawn xenotypes replaced")
                continue
            }
            if name == "stuff" {
                element.setStringValue("Cloth", resolvingEntities: false)
                record("Stuff refs replaced")
                continue
            }
            if identityFields.contains(name), let boundary = objectBoundary(containing: element), boundary.directText("def") != "Human" {
                if detachPreservingParallelDictionary(boundary) {
                    removedObjectIDs.formUnion(objectIDs(in: boundary))
                    record("Owned identity objects removed")
                }
                continue
            }
            element.setStringValue("null", resolvingEntities: false)
            record("Owned scalar references nulled")
        }
        return removedObjectIDs
    }

    private func objectBoundary(containing element: XMLElement) -> XMLElement? {
        var current = element.parent
        while let node = current {
            guard let candidate = node as? XMLElement else {
                current = node.parent
                continue
            }
            if ["li", "thing"].contains(candidate.name ?? "") { return candidate }
            if ["savegame", "game", "meta"].contains(candidate.name ?? "") { return nil }
            current = candidate.parent
        }
        return nil
    }

    private func objectIDs(in element: XMLElement) -> Set<String> {
        var result = Set<String>()
        for name in ["id", "loadID"] {
            guard let value = element.directTextOptional(name), value != "null" else { continue }
            result.insert(value)
        }
        return result
    }

    private func pruneReferences(to removedObjectIDs: Set<String>, in root: XMLElement, record: (Int) -> Void) {
        guard !removedObjectIDs.isEmpty else { return }
        var removed = 0
        for element in allElements(root) where element.childrenElements.isEmpty {
            guard let name = element.name,
                  !["id", "loadID", "index"].contains(name),
                  let value = element.trimmedText,
                  value != "null",
                  removedObjectIDs.contains(where: { removedID in
                      if value.hasSuffix("_\(removedID)") { return true }
                      guard !removedID.allSatisfy({ $0.isNumber }) else { return false }
                      return value == removedID
                  }) else { continue }
            if name == "li" {
                guard detachPreservingParallelDictionary(element) else { continue }
            } else {
                element.setStringValue("null", resolvingEntities: false)
            }
            removed += 1
        }
        if removed > 0 { record(removed) }
    }

    private func invalidBodyPartReferenceCount(in elements: [XMLElement]) -> Int {
        elements.reduce(into: 0) { count, element in
            guard element.name == "part",
                  let body = element.directTextOptional("body"),
                  let index = element.directTextOptional("index"),
                  body == "null" || index == "null" else { return }
            count += 1
        }
    }

    private func shouldRemoveContentNode(_ element: XMLElement, mod: ModScan, removableDefs: Set<String>) -> Bool {
        let def = element.directText("def")
        if !def.isEmpty, removableDefs.contains(def) { return true }
        let thingDef = element.directText("thingDef")
        if !thingDef.isEmpty, mod.itemDefs.contains(thingDef) { return true }
        return false
    }

    private func contentRemovalTarget(for element: XMLElement) -> XMLElement {
        var current: XMLNode? = element
        while let node = current {
            guard let candidate = node as? XMLElement else {
                current = node.parent
                continue
            }
            if ["li", "thing"].contains(candidate.name ?? ""),
               candidate.directText("def") == "MinifiedThing",
               candidate.directElement("innerContainer") != nil {
                return candidate
            }
            current = candidate.parent
        }
        return element
    }

    @discardableResult
    private func detachPreservingParallelDictionary(_ element: XMLElement) -> Bool {
        guard let list = element.parent as? XMLElement else { return false }
        guard ["keys", "values"].contains(list.name ?? "") else {
            element.detach()
            return true
        }
        guard let container = list.parent as? XMLElement,
              let keys = container.directElement("keys"),
              let values = container.directElement("values") else {
            return false
        }
        let keyItems = keys.childrenElements
        let valueItems = values.childrenElements
        guard keyItems.count == valueItems.count else { return false }

        let items = list.name == "keys" ? keyItems : valueItems
        guard let index = items.firstIndex(where: { $0 === element }) else { return false }
        let pairedItem = list.name == "keys" ? valueItems[index] : keyItems[index]
        pairedItem.detach()
        element.detach()
        return true
    }

    private func allElements(_ root: XMLElement) -> [XMLElement] {
        var result: [XMLElement] = [root]
        for child in root.childrenElements {
            result.append(contentsOf: allElements(child))
        }
        return result
    }
}

private extension XMLNode {
    var trimmedText: String? {
        let value = stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

private extension XMLElement {
    var childrenElements: [XMLElement] {
        children?.compactMap { $0 as? XMLElement } ?? []
    }

    func directElement(_ name: String) -> XMLElement? {
        childrenElements.first { $0.name == name }
    }

    func directText(_ name: String) -> String {
        directTextOptional(name) ?? ""
    }

    func directTextOptional(_ name: String) -> String? {
        directElement(name)?.trimmedText
    }
}

enum ManagedAssemblyTypeReader {
    static func typeNames(in data: Data) -> Set<String> {
        guard data.count >= 64,
              data.byte(at: 0) == 0x4D,
              data.byte(at: 1) == 0x5A,
              let peOffset = data.int32(at: 0x3C),
              data.int32(at: peOffset) == 0x0000_4550,
              let sectionCount = data.int16(at: peOffset + 6),
              let optionalHeaderSize = data.int16(at: peOffset + 20) else { return [] }

        let optionalHeader = peOffset + 24
        guard let magic = data.int16(at: optionalHeader) else { return [] }
        let dataDirectoryOffset: Int
        switch magic {
        case 0x10B: dataDirectoryOffset = optionalHeader + 96
        case 0x20B: dataDirectoryOffset = optionalHeader + 112
        default: return []
        }
        guard let cliRVA = data.int32(at: dataDirectoryOffset + 14 * 8), cliRVA != 0 else { return [] }

        let sectionTable = optionalHeader + optionalHeaderSize
        func fileOffset(for rva: Int) -> Int? {
            for index in 0..<sectionCount {
                let section = sectionTable + index * 40
                guard let virtualSize = data.int32(at: section + 8),
                      let virtualAddress = data.int32(at: section + 12),
                      let rawSize = data.int32(at: section + 16),
                      let rawPointer = data.int32(at: section + 20) else { continue }
                let span = max(virtualSize, rawSize)
                if rva >= virtualAddress, rva < virtualAddress + span {
                    return rawPointer + rva - virtualAddress
                }
            }
            return nil
        }

        guard let cliOffset = fileOffset(for: cliRVA),
              let metadataRVA = data.int32(at: cliOffset + 8),
              let metadataRoot = fileOffset(for: metadataRVA),
              data.int32(at: metadataRoot) == 0x424A_5342,
              let versionLength = data.int32(at: metadataRoot + 12) else { return [] }

        var streamCursor = align(metadataRoot + 16 + versionLength, to: 4)
        guard let streamCount = data.int16(at: streamCursor + 2) else { return [] }
        streamCursor += 4
        var streams: [String: (offset: Int, size: Int)] = [:]
        for _ in 0..<streamCount {
            guard let relativeOffset = data.int32(at: streamCursor),
                  let size = data.int32(at: streamCursor + 4),
                  let name = data.cString(at: streamCursor + 8, maximumLength: 32) else { return [] }
            streams[name] = (metadataRoot + relativeOffset, size)
            streamCursor = align(streamCursor + 8 + name.utf8.count + 1, to: 4)
        }

        guard let tables = streams["#~"] ?? streams["#-"],
              let strings = streams["#Strings"],
              let heapSizes = data.byte(at: tables.offset + 6),
              let valid = data.int64(at: tables.offset + 8) else { return [] }

        var rowCounts = Array(repeating: 0, count: 64)
        var rowCursor = tables.offset + 24
        for table in 0..<64 where valid & (UInt64(1) << UInt64(table)) != 0 {
            guard let count = data.int32(at: rowCursor) else { return [] }
            rowCounts[table] = count
            rowCursor += 4
        }

        let stringIndexSize = heapSizes & 0x01 == 0 ? 2 : 4
        let guidIndexSize = heapSizes & 0x02 == 0 ? 2 : 4
        func tableIndexSize(_ table: Int) -> Int { rowCounts[table] < 65_536 ? 2 : 4 }
        func codedIndexSize(_ tables: [Int], tagBits: Int) -> Int {
            let maximum = tables.map { rowCounts[$0] }.max() ?? 0
            return maximum < (1 << (16 - tagBits)) ? 2 : 4
        }

        let moduleRowSize = 2 + stringIndexSize + guidIndexSize * 3
        let resolutionScopeSize = codedIndexSize([0, 26, 35, 1], tagBits: 2)
        let typeRefRowSize = resolutionScopeSize + stringIndexSize * 2
        let typeDefOrRefSize = codedIndexSize([2, 1, 27], tagBits: 2)
        let typeDefRowSize = 4 + stringIndexSize * 2 + typeDefOrRefSize + tableIndexSize(4) + tableIndexSize(6)
        var typeDefCursor = rowCursor + rowCounts[0] * moduleRowSize + rowCounts[1] * typeRefRowSize

        func string(at index: Int) -> String? {
            guard index >= 0, index < strings.size else { return nil }
            return data.cString(at: strings.offset + index, maximumLength: strings.size - index)
        }

        var result = Set<String>()
        for _ in 0..<rowCounts[2] {
            let nameIndexOffset = typeDefCursor + 4
            guard let nameIndex = data.index(at: nameIndexOffset, size: stringIndexSize),
                  let namespaceIndex = data.index(at: nameIndexOffset + stringIndexSize, size: stringIndexSize),
                  let name = string(at: nameIndex) else { break }
            if name != "<Module>" {
                let namespace = string(at: namespaceIndex) ?? ""
                result.insert(namespace.isEmpty ? name : "\(namespace).\(name)")
            }
            typeDefCursor += typeDefRowSize
        }
        return result
    }

    private static func align(_ value: Int, to alignment: Int) -> Int {
        (value + alignment - 1) & ~(alignment - 1)
    }
}

private extension Data {
    func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return self[startIndex + offset]
    }

    func int16(at offset: Int) -> Int? {
        guard let first = byte(at: offset), let second = byte(at: offset + 1) else { return nil }
        return Int(first) | Int(second) << 8
    }

    func int32(at offset: Int) -> Int? {
        guard let a = byte(at: offset), let b = byte(at: offset + 1),
              let c = byte(at: offset + 2), let d = byte(at: offset + 3) else { return nil }
        return Int(a) | Int(b) << 8 | Int(c) << 16 | Int(d) << 24
    }

    func int64(at offset: Int) -> UInt64? {
        var result: UInt64 = 0
        for index in 0..<8 {
            guard let value = byte(at: offset + index) else { return nil }
            result |= UInt64(value) << UInt64(index * 8)
        }
        return result
    }

    func index(at offset: Int, size: Int) -> Int? {
        switch size {
        case 2: return int16(at: offset)
        case 4: return int32(at: offset)
        default: return nil
        }
    }

    func cString(at offset: Int, maximumLength: Int) -> String? {
        guard offset >= 0, maximumLength >= 0, offset < count else { return nil }
        let end = Swift.min(count, offset + maximumLength)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Swift.min(maximumLength, 64))
        for index in offset..<end {
            guard let value = byte(at: index) else { return nil }
            if value == 0 { return String(bytes: bytes, encoding: .utf8) }
            bytes.append(value)
        }
        return nil
    }
}
