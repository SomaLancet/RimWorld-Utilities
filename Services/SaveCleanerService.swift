import Foundation

protocol SaveCleanerServiceProtocol: AnyObject, Sendable {
    func scanAsync(saveURL: URL, modDirectories: [URL], configURL: URL?) async throws -> SaveCleanerReport
    func cleanAsync(saveURL: URL, modDirectories: [URL], configURL: URL?) async throws -> SaveCleanerReport
}

enum SaveCleanerError: LocalizedError {
    case invalidSave
    case noActiveDefs
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidSave:
            return "Файл не похож на сохранение RimWorld."
        case .noActiveDefs:
            return "Не удалось собрать Def'ы активных модов. Проверьте пути к Data/Mods и ModsConfig.xml."
        case .writeFailed:
            return "Не удалось записать очищенное сохранение."
        }
    }
}

final class SaveCleanerService: SaveCleanerServiceProtocol, Sendable {
    private struct DefCatalog {
        var defs: Set<String> = []
        var derivedPrefixes: Set<String> = []
        var scannedModCount = 0
    }

    private struct SaveCleanerPlan {
        var counts: [String: Int] = [:]
        var removals: [XMLElement] = []
        var replacements: [(element: XMLElement, value: String)] = []

        var previewItems: [SaveCleanerPreviewItem] {
            counts.map { key, count in
                let parts = key.components(separatedBy: "|")
                return SaveCleanerPreviewItem(
                    entity: parts[0],
                    subject: parts[1],
                    action: parts[2],
                    replacement: parts[3].isEmpty ? nil : parts[3],
                    confidence: parts[4],
                    count: count
                )
            }
            .sorted {
                if $0.entity != $1.entity { return $0.entity.localizedCaseInsensitiveCompare($1.entity) == .orderedAscending }
                return $0.subject.localizedCaseInsensitiveCompare($1.subject) == .orderedAscending
            }
        }

        mutating func record(_ entity: String, _ subject: String, _ action: String, replacement: String? = nil, confidence: String = "high", by count: Int = 1) {
            let key = [entity, subject, action, replacement ?? "", confidence].joined(separator: "|")
            counts[key, default: 0] += count
        }

        mutating func replace(_ element: XMLElement, with value: String, entity: String, subject: String, confidence: String = "high") {
            replacements.append((element, value))
            record(entity, subject, "replace", replacement: value, confidence: confidence)
        }

        mutating func remove(_ element: XMLElement, entity: String, subject: String, confidence: String = "high") {
            removals.append(element)
            record(entity, subject, "remove", confidence: confidence)
        }
    }

    func scanAsync(saveURL: URL, modDirectories: [URL], configURL: URL?) async throws -> SaveCleanerReport {
        try await Task.detached(priority: .userInitiated) {
            try self.scan(saveURL: saveURL, modDirectories: modDirectories, configURL: configURL)
        }.value
    }

    func cleanAsync(saveURL: URL, modDirectories: [URL], configURL: URL?) async throws -> SaveCleanerReport {
        try await Task.detached(priority: .userInitiated) {
            try self.clean(saveURL: saveURL, modDirectories: modDirectories, configURL: configURL)
        }.value
    }

    func scan(saveURL: URL, modDirectories: [URL], configURL: URL?) throws -> SaveCleanerReport {
        let catalog = try makeCatalog(modDirectories: modDirectories, configURL: configURL)
        guard !catalog.defs.isEmpty else { throw SaveCleanerError.noActiveDefs }
        let document = try XMLDocument(contentsOf: saveURL, options: [.nodePreserveWhitespace])
        guard let root = document.rootElement(), root.name == "savegame" else {
            throw SaveCleanerError.invalidSave
        }
        let preview = makePlan(in: root, catalog: catalog).previewItems
        return SaveCleanerReport(
            savePath: saveURL.path,
            activeDefCount: catalog.defs.count,
            scannedModCount: catalog.scannedModCount,
            unknownDefCount: Set(preview.map(\.subject)).count,
            previewItems: preview,
            outputPath: nil
        )
    }

    func clean(saveURL: URL, modDirectories: [URL], configURL: URL?) throws -> SaveCleanerReport {
        let catalog = try makeCatalog(modDirectories: modDirectories, configURL: configURL)
        guard !catalog.defs.isEmpty else { throw SaveCleanerError.noActiveDefs }
        let document = try XMLDocument(contentsOf: saveURL, options: [.nodePreserveWhitespace])
        guard let root = document.rootElement(), root.name == "savegame" else {
            throw SaveCleanerError.invalidSave
        }
        let plan = makePlan(in: root, catalog: catalog)
        let preview = plan.previewItems
        apply(plan)

        let outputURL = cleanedURL(for: saveURL)
        let data = document.xmlData(options: [])
        guard !data.isEmpty else { throw SaveCleanerError.writeFailed }
        try data.write(to: outputURL, options: .atomic)

        return SaveCleanerReport(
            savePath: saveURL.path,
            activeDefCount: catalog.defs.count,
            scannedModCount: catalog.scannedModCount,
            unknownDefCount: Set(preview.map(\.subject)).count,
            previewItems: preview,
            outputPath: outputURL.path
        )
    }

    private func makeCatalog(modDirectories: [URL], configURL: URL?) throws -> DefCatalog {
        let activePackageIds = try activeMods(from: configURL)
        var catalog = DefCatalog()
        var scannedPaths: Set<String> = []

        for root in modDirectories.map(\.standardizedFileURL) {
            for dataFolder in dataContentFolders(under: root) {
                let path = dataFolder.path
                guard scannedPaths.insert(path).inserted else { continue }
                catalog.defs.formUnion(defs(under: dataFolder))
                catalog.derivedPrefixes.formUnion(templateGeneratedPrefixes(under: dataFolder))
                catalog.derivedPrefixes.formUnion(sourceGeneratedPrefixes(under: dataFolder))
                catalog.scannedModCount += 1
            }

            for modFolder in candidateModFolders(under: root) {
                let path = modFolder.path
                guard scannedPaths.insert(path).inserted else { continue }
                guard shouldIndexMod(at: modFolder, activePackageIds: activePackageIds) else { continue }
                catalog.defs.formUnion(defs(under: modFolder))
                catalog.derivedPrefixes.formUnion(templateGeneratedPrefixes(under: modFolder))
                catalog.derivedPrefixes.formUnion(sourceGeneratedPrefixes(under: modFolder))
                catalog.scannedModCount += 1
            }
        }

        catalog.defs.formUnion(["Human", "MinifiedThing", "Colonist", "Baseline", "Synthread"])
        catalog.derivedPrefixes.formUnion(inferredDerivedPrefixes(from: catalog.defs))
        return catalog
    }

    private func activeMods(from url: URL?) throws -> Set<String> {
        guard let url else { return [] }
        return Set(try XMLValues.read(url).list("/ModsConfigData/activeMods/li").map { $0.lowercased() })
    }

    private func shouldIndexMod(at url: URL, activePackageIds: Set<String>) -> Bool {
        guard !activePackageIds.isEmpty else { return true }
        guard let aboutURL = aboutURL(for: url),
              let xml = try? XMLValues.read(aboutURL),
              let packageId = xml.firstModMetadataValue("packageId") else {
            return false
        }
        return activePackageIds.contains(packageId.lowercased())
    }

    private func candidateModFolders(under root: URL) -> [URL] {
        var result: [URL] = []
        if aboutURL(for: root) != nil {
            result.append(root)
        }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
        result.append(contentsOf: children.filter { aboutURL(for: $0) != nil })
        return result
    }

    private func dataContentFolders(under root: URL) -> [URL] {
        let dataURL: URL?
        if root.lastPathComponent.caseInsensitiveCompare("Data") == .orderedSame {
            dataURL = root
        } else if root.lastPathComponent.caseInsensitiveCompare("Mods") == .orderedSame {
            dataURL = root.deletingLastPathComponent().appendingPathComponent("Data", isDirectory: true)
        } else {
            dataURL = nil
        }
        guard let dataURL else { return [] }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: dataURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
        return children.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Defs", isDirectory: true).path) }
    }

    private func aboutURL(for url: URL) -> URL? {
        [
            url.appendingPathComponent("About/About.xml"),
            url.appendingPathComponent("About/about.xml")
        ].first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func defs(under url: URL) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var result = Set<String>()
        for case let file as URL in enumerator {
            guard file.pathExtension.lowercased() == "xml" else { continue }
            if file.pathComponents.contains(where: { $0.caseInsensitiveCompare("Defs") == .orderedSame }) {
                result.formUnion(DefNameReader.read(file))
                result.formUnion(defReferences(in: file))
            } else if file.pathComponents.contains(where: { $0.caseInsensitiveCompare("Patches") == .orderedSame }) {
                result.formUnion(patchAddedDefs(in: file))
                result.formUnion(defReferences(in: file))
            } else if file.pathComponents.contains(where: { $0.caseInsensitiveCompare("DefInjected") == .orderedSame }) {
                result.formUnion(defInjectedNames(in: file))
            }
        }
        return result
    }

    private func defInjectedNames(in url: URL) -> Set<String> {
        guard let document = try? XMLDocument(contentsOf: url, options: []),
              let root = document.rootElement() else {
            return []
        }
        var result = Set<String>()
        for child in root.childrenElements {
            guard let name = child.name,
                  let defName = name.split(separator: ".", maxSplits: 1).first,
                  looksLikeDefReference(String(defName)) else {
                continue
            }
            result.insert(String(defName))
        }
        return result
    }

    private func defReferences(in url: URL) -> Set<String> {
        guard let document = try? XMLDocument(contentsOf: url, options: []),
              let root = document.rootElement() else {
            return []
        }
        var result = Set<String>()
        for element in allElements(root) {
            guard isDefReferenceElement(element),
                  let value = element.trimmedText,
                  looksLikeDefReference(value) else {
                continue
            }
            result.insert(value)
        }
        return result
    }

    private func isDefReferenceElement(_ element: XMLElement) -> Bool {
        guard let name = element.name else { return false }
        if name == "li" { return true }
        return name.hasSuffix("Def")
    }

    private func patchAddedDefs(in url: URL) -> Set<String> {
        guard let document = try? XMLDocument(contentsOf: url, options: []),
              let root = document.rootElement(),
              root.name == "Patch" else {
            return []
        }
        var result = Set<String>()
        for operation in allElements(root) {
            let xpath = operation.directText("xpath")
            guard operation.attribute(forName: "Class")?.stringValue == "PatchOperationAdd",
                  xpath == "/Defs" || xpath == "Defs",
                  let value = operation.directElement("value") else {
                continue
            }
            for child in value.childrenElements {
                guard child.name?.hasSuffix("Def") == true,
                      let defName = child.directTextOptional("defName") else {
                    continue
                }
                result.insert(defName)
            }
        }
        return result
    }

    private func sourceGeneratedPrefixes(under url: URL) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result = Set<String>()
        let pattern = #""([A-Za-z][A-Za-z0-9_.\-]*_)"\s*\+\s*[A-Za-z_][A-Za-z0-9_\.]*\.defName"#
        for case let file as URL in enumerator where file.pathExtension.lowercased() == "cs" {
            guard let source = try? String(contentsOf: file) else { continue }
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: source, range: range) {
                guard let prefixRange = Range(match.range(at: 1), in: source) else { continue }
                result.insert(String(source[prefixRange]))
            }
        }
        return result
    }

    private func templateGeneratedPrefixes(under url: URL) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result = Set<String>()
        for case let file as URL in enumerator {
            guard file.pathExtension.lowercased() == "xml",
                  file.pathComponents.contains(where: { $0.caseInsensitiveCompare("Defs") == .orderedSame }),
                  let document = try? XMLDocument(contentsOf: file, options: []),
                  let root = document.rootElement() else {
                continue
            }
            for element in allElements(root) {
                guard element.name?.localizedCaseInsensitiveContains("TemplateDef") == true,
                      let defName = element.directTextOptional("defName"),
                      looksLikeDefReference(defName) else {
                    continue
                }
                result.insert("\(defName)_")
            }
        }
        return result
    }

    private func inferredDerivedPrefixes(from defs: Set<String>) -> Set<String> {
        var result = Set<String>()
        for def in defs {
            guard let underscore = def.firstIndex(of: "_") else { continue }
            let prefix = String(def[...underscore])
            let base = String(def[def.index(after: underscore)...])
            guard !base.isEmpty, defs.contains(base) else { continue }
            result.insert(prefix)
        }
        return result
    }

    private func makePlan(in root: XMLElement, catalog: DefCatalog) -> SaveCleanerPlan {
        var plan = SaveCleanerPlan()
        var removedContentNodes = Set<ObjectIdentifier>()
        var removedObjectIDs = Set<String>()

        for pawn in allElements(root) where isSerializedPawn(pawn) && pawn.directText("def") != "Human" {
            let def = pawn.directText("def")
            let kind = pawn.directText("kindDef")
            guard isUnknownDef(def, catalog: catalog) || isUnknownDef(kind, catalog: catalog) else { continue }
            removedContentNodes.insert(ObjectIdentifier(pawn))
            if let id = pawn.directTextOptional("id"), id != "null" {
                removedObjectIDs.insert(id)
            }
            plan.remove(
                pawn,
                entity: "Things and records",
                subject: kind.isEmpty ? def : kind
            )
        }

        var stack: [(element: XMLElement, insideRecorder: Bool, insideRecordData: Bool)] = [
            (root, false, false)
        ]

        while let item = stack.popLast() {
            let element = item.element
            if hasAncestorScheduledForRemoval(element, identifiers: removedContentNodes) { continue }
            let insideRecorder = item.insideRecorder || element.name == "recorder"
            let insideRecordData = item.insideRecordData || element.directElement("recordsDeflate") != nil
            stack.append(contentsOf: element.childrenElements.reversed().map { ($0, insideRecorder, insideRecordData) })

            if element.directText("def") == "Human" {
                planPawnChanges(in: element, catalog: catalog, plan: &plan)
            }

            if ["li", "thing"].contains(element.name ?? ""),
               element.directText("def") != "Human",
               !insideRecorder,
               !insideRecordData,
               shouldRemoveContentNode(element, catalog: catalog) {
                let target = contentRemovalTarget(for: element)
                let identifier = ObjectIdentifier(target)
                if !removedContentNodes.contains(identifier) {
                    removedContentNodes.insert(identifier)
                    let subject = element.directText("def").isEmpty ? element.directText("thingDef") : element.directText("def")
                    plan.remove(target, entity: "Things and records", subject: subject.isEmpty ? "Saved record" : subject)
                }
            }

            guard !insideRecorder, !insideRecordData else { continue }
            guard let name = element.name, let value = element.trimmedText, isUnknownDef(value, catalog: catalog) else { continue }
            if ["xenotype", "originalXenotypeDef"].contains(name) {
                plan.replace(element, with: "Baseline", entity: "Xenotypes", subject: value)
            } else if name == "stuff" {
                plan.replace(element, with: "Synthread", entity: "Stuff", subject: value)
            } else if name == "kindDef" {
                plan.replace(element, with: "Colonist", entity: "Pawn kinds", subject: value)
            } else if ["peq", "thingDef", "source"].contains(name) {
                plan.replace(element, with: "null", entity: "Scalar references", subject: "\(name): \(value)", confidence: "medium")
            }
        }

        planDanglingReferenceChanges(
            in: root,
            removedObjectIDs: removedObjectIDs,
            removedContentNodes: removedContentNodes,
            plan: &plan
        )

        return plan
    }

    private func planDanglingReferenceChanges(
        in root: XMLElement,
        removedObjectIDs: Set<String>,
        removedContentNodes: Set<ObjectIdentifier>,
        plan: inout SaveCleanerPlan
    ) {
        guard !removedObjectIDs.isEmpty else { return }
        for element in allElements(root) where element.childrenElements.isEmpty {
            guard !hasAncestorScheduledForRemoval(element, identifiers: removedContentNodes),
                  let name = element.name,
                  !["id", "loadID"].contains(name),
                  let value = element.trimmedText,
                  value != "null",
                  removedObjectIDs.contains(where: { value == $0 || value.hasSuffix("_\($0)") }) else {
                continue
            }
            let subject = "Reference to \(value)"
            if name == "li" {
                plan.remove(element, entity: "Things and records", subject: subject)
            } else {
                plan.replace(element, with: "null", entity: "Things and records", subject: subject)
            }
        }
    }

    private func isSerializedPawn(_ element: XMLElement) -> Bool {
        guard element.directElement("def") != nil,
              element.directElement("kindDef") != nil,
              element.directElement("id") != nil else {
            return false
        }
        let className = element.attribute(forName: "Class")?.stringValue ?? ""
        return className.localizedCaseInsensitiveContains("Pawn")
    }

    private func hasAncestorScheduledForRemoval(
        _ element: XMLElement,
        identifiers: Set<ObjectIdentifier>
    ) -> Bool {
        var current: XMLNode? = element
        while let node = current {
            if let candidate = node as? XMLElement,
               identifiers.contains(ObjectIdentifier(candidate)) {
                return true
            }
            current = node.parent
        }
        return false
    }

    private func apply(_ plan: SaveCleanerPlan) {
        var detached = Set<ObjectIdentifier>()
        for element in plan.removals {
            let identifier = ObjectIdentifier(element)
            guard detached.insert(identifier).inserted else { continue }
            element.detach()
        }

        for replacement in plan.replacements {
            replacement.element.setStringValue(replacement.value, resolvingEntities: false)
        }
    }

    private func planPawnChanges(
        in pawn: XMLElement,
        catalog: DefCatalog,
        plan: inout SaveCleanerPlan
    ) {
        if let kind = pawn.directElement("kindDef"), let value = kind.trimmedText, isUnknownDef(value, catalog: catalog) {
            plan.replace(kind, with: "Colonist", entity: "Pawn kinds", subject: value)
        }

        guard let genes = pawn.directElement("genes") else { return }
        var removedGeneIds = Set<String>()
        for listName in ["endogenes", "xenogenes"] {
            guard let geneList = genes.directElement(listName) else { continue }
            for gene in geneList.childrenElements where isUnknownGeneDef(gene.directText("def"), catalog: catalog) {
                let def = gene.directText("def")
                let loadID = gene.directText("loadID")
                if !loadID.isEmpty { removedGeneIds.insert("Gene_\(loadID)") }
                plan.remove(gene, entity: "Genes", subject: def.isEmpty ? "Gene" : def)
            }
        }

        var stack = [genes]
        while let element = stack.popLast() {
            stack.append(contentsOf: element.childrenElements.reversed())
            guard element.name == "overriddenByGene",
                  let value = element.trimmedText,
                  removedGeneIds.contains(value) else {
                continue
            }
            plan.replace(element, with: "null", entity: "Gene override references", subject: value)
        }

        if let xenotype = genes.directElement("xenotype"),
           let value = xenotype.trimmedText,
           isUnknownDef(value, catalog: catalog) {
            plan.replace(xenotype, with: "Baseline", entity: "Xenotypes", subject: value)
        }
    }

    private func shouldRemoveContentNode(_ element: XMLElement, catalog: DefCatalog) -> Bool {
        if ["endogenes", "xenogenes"].contains(element.parent?.name ?? "") {
            return false
        }
        let def = element.directText("def")
        if !def.isEmpty, isUnknownDef(def, catalog: catalog) { return true }
        let thingDef = element.directText("thingDef")
        if !thingDef.isEmpty, isUnknownDef(thingDef, catalog: catalog) { return true }
        let stuff = element.directText("stuff")
        if !stuff.isEmpty, isUnknownDef(stuff, catalog: catalog) { return true }
        let source = element.directText("source")
        if !source.isEmpty, isUnknownDef(source, catalog: catalog) { return true }
        return false
    }

    private func isUnknownDef(_ value: String, catalog: DefCatalog) -> Bool {
        let safeValues: Set<String> = ["null", "None", "nil", "True", "False", "Male", "Female"]
        guard !safeValues.contains(value),
              !isProtectedGeneratedOrLoadId(value),
              looksLikeDefReference(value) else { return false }
        return !isKnownDef(value, catalog: catalog)
    }

    private func isUnknownGeneDef(_ value: String, catalog: DefCatalog) -> Bool {
        guard isUnknownDef(value, catalog: catalog) else { return false }
        return !isKnownSuffixGeneratedGene(value, catalog: catalog)
    }

    private func isKnownDef(_ value: String, catalog: DefCatalog) -> Bool {
        if catalog.defs.contains(value) {
            return true
        }
        for prefix in catalog.derivedPrefixes where value.hasPrefix(prefix) {
            let baseDef = String(value.dropFirst(prefix.count))
            if catalog.defs.contains(baseDef) {
                return true
            }
        }
        for prefix in ["Psytrainer_", "Techprint_"] where value.hasPrefix(prefix) {
            let baseDef = String(value.dropFirst(prefix.count))
            if catalog.defs.contains(baseDef) {
                return true
            }
        }
        return false
    }

    private func isKnownSuffixGeneratedGene(_ value: String, catalog: DefCatalog) -> Bool {
        guard let separator = value.lastIndex(of: "_"), separator > value.startIndex else {
            return false
        }
        let baseDef = String(value[..<separator])
        return catalog.defs.contains(baseDef)
    }

    private func isProtectedGeneratedOrLoadId(_ value: String) -> Bool {
        for prefix in ["Thing_", "Pawn_", "Faction_", "Gene_"] where value.hasPrefix(prefix) {
            return true
        }
        for prefix in ["Psytrainer_", "Techprint_"] where value.hasPrefix(prefix) {
            return true
        }
        return false
    }

    private func looksLikeDefReference(_ value: String) -> Bool {
        guard value.count <= 160, !value.contains("\n"), !value.contains(" "), !value.contains("(") else { return false }
        return value.range(of: #"^[A-Za-z][A-Za-z0-9_.\-\/]*$"#, options: .regularExpression) != nil
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

    private func cleanedURL(for saveURL: URL) -> URL {
        let directory = saveURL.deletingLastPathComponent()
        let fileExtension = saveURL.pathExtension
        let baseName = saveURL.deletingPathExtension().lastPathComponent
        return directory
            .appendingPathComponent("\(baseName) [save-cleaned]")
            .appendingPathExtension(fileExtension)
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
