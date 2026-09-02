import Foundation

protocol RimWorldAnalyzerProtocol: AnyObject, Sendable {
    func analyzeAsync(save: URL, modDirectories: [URL], config: URL?, log: URL?) async throws -> AnalysisReport
}

final class RimWorldAnalyzer: RimWorldAnalyzerProtocol, Sendable {
    private struct ContentIndex {
        var defOwners: [String: [ModInfo]] = [:]
        var assemblyOwners: [String: [ModInfo]] = [:]
    }

    private struct ModFingerprint {
        let mod: ModInfo
        let packageId: String
        let name: String?
        let workshopId: String?
        let assemblies: [String]
    }

    private func parseSave(_ url: URL) throws -> (String?, [ModInfo]) {
        let xml = try XMLValues.read(url)
        guard xml.paths.contains("/savegame/meta") else {
            throw AnalyzerError.invalidSave
        }
        let ids = xml.list("/savegame/meta/modIds/li")
        let names = xml.list("/savegame/meta/modNames/li")
        let mods = ids.enumerated().map { index, id in
            ModInfo(packageId: id, name: index < names.count ? names[index] : nil, path: nil)
        }
        return (xml.first("/savegame/meta/gameVersion"), mods)
    }

    private func installedMods(in directories: [URL]) -> [ModInfo] {
        let fileManager = FileManager.default
        var found: [String: ModInfo] = [:]
        for directory in directories {
            guard let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                let aboutURL = child.appendingPathComponent("About/About.xml")
                guard fileManager.fileExists(atPath: aboutURL.path),
                      let xml = try? XMLValues.read(aboutURL),
                      let packageId = xml.firstModMetadataValue("packageId") else { continue }
                let key = packageId.lowercased()
                if found[key] == nil {
                    found[key] = ModInfo(
                        packageId: packageId,
                        name: xml.firstModMetadataValue("name"),
                        path: child.path
                    )
                }
            }
        }
        return found.values.sorted { $0.packageId.localizedCaseInsensitiveCompare($1.packageId) == .orderedAscending }
    }

    private func activeMods(from url: URL?) throws -> [String] {
        guard let url else { return [] }
        return try XMLValues.read(url).list("/ModsConfigData/activeMods/li")
    }

    private func fingerprints(for mods: [ModInfo]) -> [ModFingerprint] {
        mods.map { mod in
            let assemblyNames: [String]
            if let path = mod.path {
                let root = URL(fileURLWithPath: path, isDirectory: true)
                let versionDirectories = (try? FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                let assemblyDirectories = [root.appendingPathComponent("Assemblies", isDirectory: true)]
                    + versionDirectories.map { $0.appendingPathComponent("Assemblies", isDirectory: true) }
                var names: Set<String> = []
                for directory in assemblyDirectories {
                    let files = (try? FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    for file in files where file.pathExtension.lowercased() == "dll" {
                        let name = file.deletingPathExtension().lastPathComponent.lowercased()
                        if name.count >= 4 { names.insert(name) }
                    }
                }
                assemblyNames = Array(names)
            } else {
                assemblyNames = []
            }
            let folder = mod.path.map { URL(fileURLWithPath: $0).lastPathComponent }
            let workshopId = folder?.allSatisfy(\.isNumber) == true ? folder : nil
            return ModFingerprint(
                mod: mod,
                packageId: mod.packageId.lowercased(),
                name: mod.name?.lowercased(),
                workshopId: workshopId,
                assemblies: assemblyNames
            )
        }
    }

    private func contentIndex(for mods: [ModInfo]) -> ContentIndex {
        let fileManager = FileManager.default
        var index = ContentIndex()
        for mod in mods {
            guard let path = mod.path else { continue }
            let root = URL(fileURLWithPath: path, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let file as URL in enumerator {
                let pathParts = file.pathComponents.map { $0.lowercased() }
                if file.pathExtension.lowercased() == "dll", pathParts.contains("assemblies") {
                    let assembly = file.deletingPathExtension().lastPathComponent.lowercased()
                    if assembly.count >= 3, !(index.assemblyOwners[assembly]?.contains(mod) ?? false) {
                        index.assemblyOwners[assembly, default: []].append(mod)
                    }
                } else if file.pathExtension.lowercased() == "xml", pathParts.contains("defs") {
                    for defName in DefNameReader.read(file) where !(index.defOwners[defName]?.contains(mod) ?? false) {
                        index.defOwners[defName, default: []].append(mod)
                    }
                }
            }
        }
        return index
    }

    private func saveFindings(
        references: SaveReferenceReader,
        index: ContentIndex,
        activeIds: Set<String>,
        missingMods: [ModInfo]
    ) throws -> ([SaveFinding], Int, Int) {
        var findings: [SaveFinding] = []

        for (defName, count) in references.defs {
            guard let owners = index.defOwners[defName], !owners.isEmpty else { continue }
            if owners.allSatisfy({ !activeIds.contains($0.packageId.lowercased()) }), let owner = owners.first {
                findings.append(SaveFinding(
                    kind: "def_from_inactive_mod",
                    value: defName,
                    count: count,
                    relatedMod: owner,
                    confidence: owners.count == 1 ? "высокая" : "средняя",
                    evidence: "defName найден в Defs мода, которого нет в текущем активном списке"
                ))
            }
        }

        let systemPrefixes = ["Verse.", "RimWorld.", "System.", "UnityEngine.", "HarmonyLib.", "Microsoft.", "Mono.", "Newtonsoft.", "Steamworks."]
        for (className, count) in references.classes {
            if systemPrefixes.contains(where: { className.hasPrefix($0) }) { continue }
            let lower = className.lowercased()
            let owners = index.assemblyOwners
                .filter { assembly, _ in lower == assembly || lower.hasPrefix(assembly + ".") }
                .flatMap(\.value)
            let uniqueOwners = Array(Set(owners))
            if !uniqueOwners.isEmpty,
               uniqueOwners.allSatisfy({ !activeIds.contains($0.packageId.lowercased()) }),
               let owner = uniqueOwners.first {
                findings.append(SaveFinding(
                    kind: "class_from_inactive_mod",
                    value: className,
                    count: count,
                    relatedMod: owner,
                    confidence: uniqueOwners.count == 1 ? "высокая" : "средняя",
                    evidence: "namespace совпадает с DLL мода, которого нет в текущем активном списке"
                ))
                continue
            }

            if let missing = missingMods.first(where: { mod in
                let tokens = (mod.packageId + "." + (mod.name ?? ""))
                    .lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count >= 4 }
                return tokens.contains { lower.hasPrefix($0 + ".") || lower.contains("." + $0 + ".") }
            }) {
                findings.append(SaveFinding(
                    kind: "class_from_missing_mod",
                    value: className,
                    count: count,
                    relatedMod: missing,
                    confidence: "низкая",
                    evidence: "namespace похож на packageId или название отсутствующего мода"
                ))
            }
        }

        findings.sort {
            let left = $0.relatedMod?.packageId ?? ""
            let right = $1.relatedMod?.packageId ?? ""
            return left == right ? $0.count > $1.count : left < right
        }
        return (findings, references.classes.values.reduce(0, +), references.defs.values.reduce(0, +))
    }

    private func structuralIssues(from references: SaveReferenceReader) -> [StructuralIssue] {
        let humanRequiredFields = ["id", "def", "kindDef", "name", "gender", "ageTracker"]
        let ageRequiredFields = ["ageBiologicalTicks", "birthAbsTicks"]

        var issues: [StructuralIssue] = []

        for (id, count) in references.serializedIdCounts where count > 1 {
            let matchingPawn = references.pawns.first { $0.id == id }
            let objectType = matchingPawn.flatMap { $0.defName.isEmpty ? nil : $0.defName } ?? "SerializedObject"
            issues.append(StructuralIssue(
                objectId: id,
                objectName: matchingPawn?.displayName ?? id,
                objectType: objectType,
                field: "id",
                problem: "duplicate (\(count)×)",
                level: "problem"
            ))
        }

        for (id, count) in references.pawnReferences where references.pawnIdCounts[id] == nil {
            issues.append(StructuralIssue(
                objectId: id,
                objectName: id,
                objectType: "PawnReference",
                field: "reference",
                problem: "target missing (\(count)×)",
                level: "problem"
            ))
        }

        func appendIssue(for pawn: PawnSnapshot, field: String, problem: String, level: String = "problem") {
            issues.append(StructuralIssue(
                objectId: pawn.id,
                objectName: pawn.displayName,
                objectType: pawn.defName.isEmpty ? "Pawn" : pawn.defName,
                field: field,
                problem: problem,
                level: level
            ))
        }

        for pawn in references.pawns where pawn.defName == "Human" {
            for field in humanRequiredFields where !pawn.directFields.contains(field) {
                appendIssue(
                    for: pawn,
                    field: "Pawn.\(field)",
                    problem: "missing",
                    level: field == "gender" ? "notification" : "problem"
                )
            }

            if pawn.directFields.contains("ageTracker") {
                for field in ageRequiredFields where !pawn.ageTrackerFields.contains(field) {
                    appendIssue(for: pawn, field: "Pawn.ageTracker.\(field)", problem: "missing")
                }
            }

            if pawn.directFields.contains("name") {
                if pawn.nameClass.isEmpty {
                    appendIssue(for: pawn, field: "Pawn.name.Class", problem: "missing")
                }

                if pawn.nameClass == "NameTriple" || pawn.nameClass.contains("NameTriple") {
                    let hasAnyTripleNamePart = !pawn.first.isEmpty || !pawn.nick.isEmpty || !pawn.last.isEmpty
                    if !hasAnyTripleNamePart {
                        appendIssue(for: pawn, field: "Pawn.name", problem: "empty")
                    }
                } else if pawn.nameClass == "NameSingle", !pawn.nameFields.contains("name"), !pawn.nameTextPresent {
                    appendIssue(for: pawn, field: "Pawn.name.name", problem: "missing")
                } else if pawn.nameClass.isEmpty && pawn.nameFields.isEmpty && !pawn.nameTextPresent {
                    appendIssue(for: pawn, field: "Pawn.name", problem: "empty")
                }
            }
        }

        return issues.sorted {
            if $0.objectName == $1.objectName {
                return $0.field < $1.field
            }
            return $0.objectName.localizedCaseInsensitiveCompare($1.objectName) == .orderedAscending
        }
    }

    private func suspectedMods(in context: String, fingerprints: [ModFingerprint]) -> ([ModInfo], String, String)? {
        let lower = context.lowercased()
        let infrastructurePackages: Set<String> = ["brrainz.harmony", "ludeon.rimworld"]
        var scored: [(ModFingerprint, Int, String)] = []
        for fingerprint in fingerprints {
            var score = 0
            var evidence: [String] = []
            if lower.contains(fingerprint.packageId) {
                score += 100
                evidence.append("packageId \(fingerprint.mod.packageId)")
            }
            if let workshopId = fingerprint.workshopId,
               lower.range(of: #"(?:/|\\)"# + NSRegularExpression.escapedPattern(for: workshopId) + #"(?:/|\\)"#, options: .regularExpression) != nil {
                score += 100
                evidence.append("Workshop \(workshopId)")
            }
            if let name = fingerprint.name,
               name.count >= 5,
               !infrastructurePackages.contains(fingerprint.packageId),
               lower.contains(name) {
                score += 80
                evidence.append("название мода")
            }
            if !infrastructurePackages.contains(fingerprint.packageId),
               let assembly = fingerprint.assemblies.sorted(by: { $0.count > $1.count }).first(where: { lower.contains($0) }) {
                score += 90
                evidence.append("DLL/namespace \(assembly)")
            }
            if score > 0 { scored.append((fingerprint, score, evidence.joined(separator: ", "))) }
        }
        let ordered = scored.sorted { $0.1 > $1.1 }
        let matches = ordered.filter { $0.1 >= 80 }
        guard let best = matches.first else { return nil }
        var seen: Set<String> = []
        let mods = matches.compactMap { item -> ModInfo? in
            seen.insert(item.0.mod.packageId.lowercased()).inserted ? item.0.mod : nil
        }
        let evidence = matches.map { "\($0.0.mod.packageId): \($0.2)" }.joined(separator: "; ")
        let confidence = best.1 >= 100 ? "высокая" : "средняя"
        return (mods, confidence, evidence)
    }

    private func logIssues(from url: URL?, installedMods: [ModInfo], index: ContentIndex) throws -> [LogIssue] {
        guard let url else { return [] }
        let contents = try String(contentsOf: url, encoding: .utf8)
        let patterns: [(String, String, String)] = [
            ("duplicate_load_id", "critical", #"^Exception registering .*same key has already been added.*"#),
            ("missing_object_reference", "problem", #"^Could not resolve reference to object with loadID .*"#),
            ("missing_definition", "problem", #"^(?:Could not load reference to .*|Could not resolve cross-reference.*|Failed to find .*Def named .*)"#),
            ("missing_type", "problem", #"^(?:Could not find (?:type named|class ).*|TypeLoadException:.*)"#),
            ("serialization_error", "critical", #"^(?:SaveableFromNode exception:.*|Exception loading .*|Error while loading .*)"#),
            ("post_load_error", "critical", #"^Could not do PostLoadInit .*"#),
            ("null_data", "problem", #"^(?:Null key while loading dictionary.*|Some .* had null .* after loading\.|[0-9]+ .* had null roots? after loading\.)"#),
            ("invalid_object_state", "problem", #"^(?:Spawning destroyed thing .*|Couldn't add thing .*|Spawned thing with 0 stackCount.*|Could not find think node with key .*)"#),
            ("runtime_exception", "critical", #"^Exception filling window .*"#),
            ("xml_error", "problem", #"^XML error:.*"#),
            ("patch_error", "problem", #"(?:Patch operation.*(?:failed|error)|Error in static constructor|Error (?:during|while) patching).*"#),
            ("exception", "problem", #"(?:Exception|Error) while .*"#),
            ("exception", "problem", #"^[A-Za-z_][A-Za-z0-9_.+`]*Exception:.*"#),
            ("duplicate_definition", "problem", #".*(?:duplicate|already has a definition).*"#)
        ]
        let regexes = patterns.compactMap { category, severity, pattern in
            try? (category, severity, NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
        }
        let lines = contents.components(separatedBy: .newlines)
        let modFingerprints = fingerprints(for: installedMods)
        var counts: [String: (String, String, String, Int, String)] = [:]
        for (lineIndex, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let lowerLine = line.lowercased()
            if lowerLine.contains("0 failed") || lowerLine.contains("threadabortexception") { continue }
            let range = NSRange(line.startIndex..., in: line)
            for (category, severity, regex) in regexes {
                guard let match = regex.firstMatch(in: line, range: range),
                      let swiftRange = Range(match.range, in: line) else { continue }
                let message = String(line[swiftRange]).replacingOccurrences(
                    of: #"\s+"#, with: " ", options: .regularExpression
                )
                let shortened = String(message.prefix(500))
                let key = logGroupingKey(category: category, message: shortened)
                let current = counts[key]
                let start = max(0, lineIndex - 2)
                let end = min(lines.count, lineIndex + 13)
                let context = lines[start..<end].joined(separator: "\n")
                counts[key] = (category, severity, current?.2 ?? shortened, (current?.3 ?? 0) + 1, current?.4 ?? context)
                break
            }
        }
        return counts.values
            .map { category, severity, message, count, context in
                var relatedMods: [ModInfo] = []
                var evidence: [String] = []
                var confidence: String?
                if category == "missing_definition",
                   let regex = try? NSRegularExpression(pattern: #"\bnamed\s+([^\s.]+)"#, options: [.caseInsensitive]),
                   let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                   match.numberOfRanges > 1,
                   let range = Range(match.range(at: 1), in: message) {
                    let defName = String(message[range])
                    let owners = index.defOwners[defName] ?? []
                    relatedMods.append(contentsOf: owners)
                    if !owners.isEmpty {
                        confidence = owners.count == 1 ? "высокая" : "средняя"
                        evidence.append("defName \(defName)")
                    }
                }
                if let attribution = suspectedMods(in: context, fingerprints: modFingerprints) {
                    relatedMods.append(contentsOf: attribution.0)
                    confidence = confidence ?? attribution.1
                    evidence.append(attribution.2)
                }
                var seen: Set<String> = []
                relatedMods = relatedMods.filter { seen.insert($0.packageId.lowercased()).inserted }
                return LogIssue(
                    category: category,
                    severity: severity,
                    message: message,
                    count: count,
                    relatedMods: relatedMods,
                    confidence: confidence,
                    evidence: evidence.isEmpty ? nil : evidence.joined(separator: "; ")
                )
            }
            .sorted {
                let ranks = ["critical": 0, "problem": 1, "warning": 2]
                let left = ranks[$0.severity] ?? 3
                let right = ranks[$1.severity] ?? 3
                if left != right { return left < right }
                return $0.count == $1.count ? $0.category < $1.category : $0.count > $1.count
            }
    }

    private func logGroupingKey(category: String, message: String) -> String {
        var normalized = message
        switch category {
        case "duplicate_load_id":
            return category
        case "missing_definition":
            normalized = normalized.replacingOccurrences(
                of: #"\bnamed\s+[^\s.]+"#,
                with: "named <def>",
                options: [.regularExpression, .caseInsensitive]
            )
        case "missing_object_reference":
            normalized = normalized.replacingOccurrences(
                of: #"\bloadID\s+\S+"#,
                with: "loadID <id>",
                options: [.regularExpression, .caseInsensitive]
            )
        case "invalid_object_state":
            normalized = normalized.replacingOccurrences(
                of: #"[A-Za-z_][A-Za-z0-9_]*[0-9]+"#,
                with: "<object>",
                options: .regularExpression
            )
        default:
            break
        }
        return category + "\u{0}" + normalized
    }

    func analyzeAsync(save: URL, modDirectories: [URL], config: URL?, log: URL?) async throws -> AnalysisReport {
        try await Task.detached(priority: .userInitiated) {
            try self.analyze(save: save, modDirectories: modDirectories, config: config, log: log)
        }.value
    }

    func analyze(save: URL, modDirectories: [URL], config: URL?, log: URL?) throws -> AnalysisReport {
        let (version, saveMods) = try parseSave(save)
        let installed = installedMods(in: modDirectories)
        let active = try activeMods(from: config)
        let installedIds = Set(installed.map { $0.packageId.lowercased() })
        let saveIds = Set(saveMods.map { $0.packageId.lowercased() })
        let activeLower = active.map { $0.lowercased() }
        let activeIds = Set(activeLower)
        let missing = modDirectories.isEmpty ? [] : saveMods.filter { !installedIds.contains($0.packageId.lowercased()) }
        let installedExtra = installed.filter { !saveIds.contains($0.packageId.lowercased()) }
        let activeExtra = active.filter { !saveIds.contains($0.lowercased()) }
        let inactive = config == nil ? [] : saveMods.filter { !activeIds.contains($0.packageId.lowercased()) }
        let saveCommon = saveMods.map { $0.packageId.lowercased() }.filter(activeIds.contains)
        let activeCommon = activeLower.filter(saveIds.contains)
        let effectiveActiveIds = config == nil ? saveIds : activeIds
        let index = contentIndex(for: installed)
        let issues = try logIssues(from: log, installedMods: installed, index: index)
        let references = try SaveReferenceReader.read(save)
        let (saveFindings, scannedClasses, scannedDefs) = try saveFindings(
            references: references,
            index: index,
            activeIds: effectiveActiveIds,
            missingMods: missing
        )
        let structuralIssues = structuralIssues(from: references)

        var notes: [String] = []
        if modDirectories.isEmpty { notes.append("Папки модов не выбраны: удалённые моды не проверялись.") }
        if config == nil { notes.append("ModsConfig.xml не выбран: активные моды и порядок не проверялись.") }
        if log == nil { notes.append("Player.log не выбран: ошибки игры не проверялись.") }
        notes.append("Связь ошибки с модом определяется эвристически по packageId, названию, Workshop-пути и DLL; связанный мод не всегда является первопричиной.")
        notes.append("Анализ содержимого сохранения выполняется только для чтения. Потенциальный остаток не означает, что соответствующий XML-узел безопасно удалять.")
        notes.append("Отчёт только диагностический. Удаление имени мода не очищает игровые объекты из сохранения.")

        return AnalysisReport(
            savePath: save.path,
            gameVersion: version,
            saveMods: saveMods,
            installedMods: installed,
            activeModIds: active,
            missingMods: missing,
            installedNotInSave: installedExtra,
            activeNotInSave: activeExtra,
            saveNotActive: inactive,
            loadOrderChanged: config == nil ? nil : saveCommon != activeCommon,
            logIssues: issues,
            saveFindings: saveFindings,
            structuralIssues: structuralIssues,
            scannedClassReferences: scannedClasses,
            scannedDefReferences: scannedDefs,
            scannedPawns: references.pawns.count,
            notes: notes
        )
    }
}
