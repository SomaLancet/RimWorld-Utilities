import Foundation

final class XMLValues: NSObject, XMLParserDelegate {
    private var elements: [String] = []
    private var text: [String] = []
    private(set) var values: [String: [String]] = [:]
    private(set) var paths: Set<String> = []

    static func read(_ url: URL) throws -> XMLValues {
        let reader = XMLValues()
        let parser = XMLParser(data: try Data(contentsOf: url))
        parser.delegate = reader
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        return reader
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        elements.append(elementName)
        text.append("")
        paths.insert("/" + elements.joined(separator: "/"))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !text.isEmpty else { return }
        text[text.count - 1] += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let path = "/" + elements.joined(separator: "/")
        let value = text.removeLast().trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { values[path, default: []].append(value) }
        elements.removeLast()
    }

    func first(_ path: String) -> String? { values[path]?.first }
    func list(_ path: String) -> [String] { values[path] ?? [] }

    func firstModMetadataValue(_ key: String) -> String? {
        first("/ModMetaData/\(key)") ?? first("/ModMetadata/\(key)")
    }
}

final class DefNameReader: NSObject, XMLParserDelegate {
    private var elements: [String] = []
    private var readingDefName = false
    private var buffer = ""
    private(set) var names: Set<String> = []

    static func read(_ url: URL) -> Set<String> {
        guard let parser = XMLParser(contentsOf: url) else { return [] }
        let reader = DefNameReader()
        parser.delegate = reader
        _ = parser.parse()
        return reader.names
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        elements.append(elementName)
        if elementName == "defName", elements.count == 3, elements.first == "Defs" {
            readingDefName = true
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingDefName { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "defName", readingDefName {
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { names.insert(value) }
            readingDefName = false
        }
        if !elements.isEmpty { elements.removeLast() }
    }
}

struct PawnSnapshot {
    var id = ""
    var defName = ""
    var kindDef = ""
    var gender = ""
    var nameClass = ""
    var first = ""
    var nick = ""
    var last = ""
    var singleName = ""
    var ageBiologicalTicks: Int64?
    var birthAbsTicks: Int64?
    var classes: [String: Int] = [:]
    var directFields: Set<String> = []
    var nameFields: Set<String> = []
    var ageTrackerFields: Set<String> = []
    var nameTextPresent = false

    var displayName: String {
        if !nick.isEmpty { return nick }
        let combined = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        return combined.isEmpty ? (singleName.isEmpty ? id : singleName) : combined
    }
}

final class SaveReferenceReader: NSObject, XMLParserDelegate {
    private static let defElements: Set<String> = [
        "def", "thingDef", "hediffDef", "factionDef", "worldObjectDef", "kindDef",
        "pawnKind", "xenotypeDef", "geneDef", "abilityDef", "traitDef", "thoughtDef",
        "questScriptDef", "terrainDef", "stuffDef", "recipeDef", "jobDef", "preceptDef"
    ]

    private var elementStack: [String] = []
    private var textStack: [String] = []
    private var pawn: PawnSnapshot?
    private var pawnRootDepth: Int?
    private(set) var classes: [String: Int] = [:]
    private(set) var defs: [String: Int] = [:]
    private(set) var pawns: [PawnSnapshot] = []
    private(set) var pawnIdCounts: [String: Int] = [:]
    private(set) var pawnReferences: [String: Int] = [:]
    private(set) var serializedIdCounts: [String: Int] = [:]

    static func read(_ url: URL) throws -> SaveReferenceReader {
        guard let parser = XMLParser(contentsOf: url) else { throw CocoaError(.fileReadCorruptFile) }
        let reader = SaveReferenceReader()
        parser.delegate = reader
        guard parser.parse() else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
        return reader
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        elementStack.append(elementName)
        textStack.append("")
        if let className = attributeDict["Class"]?.trimmingCharacters(in: .whitespacesAndNewlines), !className.isEmpty {
            classes[className, default: 0] += 1
            if className == "Pawn", pawn == nil {
                pawn = PawnSnapshot()
                pawnRootDepth = elementStack.count
            } else if pawn != nil {
                pawn?.classes[className, default: 0] += 1
            }
            if elementName == "name", pawn != nil, elementStack.count == (pawnRootDepth ?? 0) + 1 {
                pawn?.nameClass = className
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !textStack.isEmpty else { return }
        textStack[textStack.count - 1] += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let value = textStack.removeLast().trimmingCharacters(in: .whitespacesAndNewlines)
        let depth = elementStack.count
        if var currentPawn = pawn, let rootDepth = pawnRootDepth {
            if depth == rootDepth + 1 {
                currentPawn.directFields.insert(elementName)
                switch elementName {
                case "id": currentPawn.id = value
                case "def": currentPawn.defName = value
                case "kindDef": currentPawn.kindDef = value
                case "gender": currentPawn.gender = value
                case "name":
                    if !value.isEmpty {
                        currentPawn.singleName = value
                        currentPawn.nameTextPresent = true
                    }
                default: break
                }
            } else if depth == rootDepth + 2, elementStack.dropLast().last == "name" {
                currentPawn.nameFields.insert(elementName)
                switch elementName {
                case "first": currentPawn.first = value
                case "nick": currentPawn.nick = value
                case "last": currentPawn.last = value
                case "name":
                    currentPawn.singleName = value
                    currentPawn.nameTextPresent = !value.isEmpty
                default: break
                }
            } else if depth == rootDepth + 2, elementStack.dropLast().last == "ageTracker" {
                currentPawn.ageTrackerFields.insert(elementName)
                if elementName == "ageBiologicalTicks" { currentPawn.ageBiologicalTicks = Int64(value) }
                if elementName == "birthAbsTicks" { currentPawn.birthAbsTicks = Int64(value) }
            }
            pawn = currentPawn
            if depth == rootDepth {
                if !currentPawn.id.isEmpty {
                    pawnIdCounts[currentPawn.id, default: 0] += 1
                }
                pawns.append(currentPawn)
                pawn = nil
                pawnRootDepth = nil
            }
        }

        if value.range(of: #"^Thing_Human[0-9]+$"#, options: .regularExpression) != nil {
            pawnReferences[String(value.dropFirst("Thing_".count)), default: 0] += 1
        }
        if elementName == "id",
           value.count <= 200,
           value.range(of: #"^[A-Za-z][A-Za-z0-9_.-]*[0-9]+$"#, options: .regularExpression) != nil {
            serializedIdCounts[value, default: 0] += 1
        }
        if Self.defElements.contains(elementName), !value.isEmpty, value.count <= 200, !value.contains("\n") {
            defs[value, default: 0] += 1
        }
        elementStack.removeLast()
    }
}
