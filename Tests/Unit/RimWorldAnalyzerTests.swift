import Foundation
import XCTest
@testable import RimWorld_Utilities

final class RimWorldAnalyzerTests: XCTestCase {
    private var root: URL!
    private var saveURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        saveURL = root.appendingPathComponent("Colony.rws")
        try write(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <savegame><meta><gameVersion>1.6.4500</gameVersion><modNames>
            <li>Core</li><li>Missing Mod</li></modNames><modIds>
            <li>ludeon.rimworld</li><li>example.missing</li></modIds></meta><game /></savegame>
            """,
            to: saveURL
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testReadsSaveMetadata() throws {
        let report = try RimWorldAnalyzer().analyze(
            save: saveURL,
            modDirectories: [],
            config: nil,
            log: nil
        )

        XCTAssertEqual(report.gameVersion, "1.6.4500")
        XCTAssertEqual(report.saveMods.map(\.packageId), ["ludeon.rimworld", "example.missing"])
        XCTAssertEqual(report.saveMods.last?.name, "Missing Mod")
    }

    func testFindsMissingModAndLoadOrderChange() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        try addMod(in: modsURL, folder: "Core", packageId: "ludeon.rimworld", name: "Core")
        let configURL = root.appendingPathComponent("ModsConfig.xml")
        try write(
            "<ModsConfigData><activeMods><li>example.extra</li><li>example.missing</li><li>ludeon.rimworld</li></activeMods></ModsConfigData>",
            to: configURL
        )

        let report = try RimWorldAnalyzer().analyze(
            save: saveURL,
            modDirectories: [modsURL],
            config: configURL,
            log: nil
        )

        XCTAssertEqual(report.missingMods.map(\.packageId), ["example.missing"])
        XCTAssertEqual(report.activeNotInSave, ["example.extra"])
        XCTAssertEqual(report.loadOrderChanged, true)
    }

    func testReadsModMetadataAlternateRootName() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        try addMod(
            in: modsURL,
            folder: "2413156320",
            packageId: "Inglix.ApparelTaintedOnCorpseRot",
            name: "Apparel Tainted Only When Corpse Rots",
            rootElement: "ModMetadata"
        )

        let report = try RimWorldAnalyzer().analyze(
            save: saveURL,
            modDirectories: [modsURL],
            config: nil,
            log: nil
        )

        XCTAssertTrue(report.installedMods.contains {
            $0.packageId == "Inglix.ApparelTaintedOnCorpseRot"
        })
    }

    func testModRemovalReadsModMetadataAlternateRootName() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let modURL = try addMod(
            in: modsURL,
            folder: "2413156320",
            packageId: "Inglix.ApparelTaintedOnCorpseRot",
            name: "Apparel Tainted Only When Corpse Rots",
            rootElement: "ModMetadata"
        )

        let scan = try ModRemovalService().scan(saveURL: saveURL, modURL: modURL)

        XCTAssertEqual(scan.packageId, "Inglix.ApparelTaintedOnCorpseRot")
        XCTAssertEqual(scan.modName, "Apparel Tainted Only When Corpse Rots")
    }

    func testGroupsRepeatedLogIssues() throws {
        let logURL = root.appendingPathComponent("Player.log")
        try write(
            """
            XML error: bad node
            XML error: bad node
            Could not find type named Old.Type
            Patch operations run, 0 failed
            System.Threading.ThreadAbortException: stopped
            """,
            to: logURL
        )

        let report = try RimWorldAnalyzer().analyze(
            save: saveURL,
            modDirectories: [],
            config: nil,
            log: logURL
        )

        XCTAssertEqual(report.logIssues.first?.count, 2)
        XCTAssertEqual(Set(report.logIssues.map(\.category)), ["xml_error", "missing_type"])
    }

    func testFindsSaveCorruptionLogFamiliesWithoutModAttribution() throws {
        let logURL = root.appendingPathComponent("Player.log")
        try write(
            """
            Could not load reference to Verse.HediffDef named AC_EmptySleeve
            Could not resolve reference to object with loadID Thing_AC_Stack123 of type Verse.Thing.
            SaveableFromNode exception: System.ArgumentException: Can't load abstract class Verse.GameComponent
            Null key while loading dictionary of Verse.ThingDef and System.Single. label=priceModifiers
            Exception registering Verse.Pawn Example with unique load ID Thing_Human42: System.ArgumentException: An item with the same key has already been added. Key: Thing_Human42
            Exception registering Verse.Gene Verse.Gene with unique load ID Gene_43: System.ArgumentException: An item with the same key has already been added. Key: Gene_43
            Exception filling window for RimWorld.Dialog_FormCaravan: System.NullReferenceException: Object reference not set to an instance of an object
            Exception filling window for RimWorld.Dialog_FormCaravan: System.NullReferenceException: Object reference not set to an instance of an object
            """,
            to: logURL
        )

        let report = try RimWorldAnalyzer().analyze(
            save: saveURL,
            modDirectories: [],
            config: nil,
            log: logURL
        )

        XCTAssertEqual(
            Set(report.logIssues.map(\.category)),
            ["missing_definition", "missing_object_reference", "serialization_error", "null_data", "duplicate_load_id", "runtime_exception"]
        )
        XCTAssertEqual(report.logIssues.first { $0.category == "duplicate_load_id" }?.count, 2)
        XCTAssertEqual(report.logIssues.first { $0.category == "duplicate_load_id" }?.severity, "critical")
        XCTAssertEqual(report.logIssues.first { $0.category == "runtime_exception" }?.count, 2)
        XCTAssertTrue(report.logIssues.allSatisfy { $0.relatedMods.isEmpty })
    }

    func testFindsDuplicateSerializedIdsAndDanglingPawnReferences() throws {
        try write(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <savegame>
              <meta><gameVersion>1.6.4500</gameVersion><modNames></modNames><modIds></modIds></meta>
              <game>
                <things>
                  <li Class="Pawn"><id>Human42</id><def>Human</def><kindDef>Colonist</kindDef><name Class="NameSingle">One</name><gender>Male</gender><ageTracker><ageBiologicalTicks>1</ageBiologicalTicks><birthAbsTicks>1</birthAbsTicks></ageTracker></li>
                  <li Class="Pawn"><id>Human42</id><def>Human</def><kindDef>Colonist</kindDef><name Class="NameSingle">Two</name><gender>Male</gender><ageTracker><ageBiologicalTicks>1</ageBiologicalTicks><birthAbsTicks>1</birthAbsTicks></ageTracker></li>
                </things>
                <targets><li>Thing_Human999</li></targets>
              </game>
            </savegame>
            """,
            to: saveURL
        )

        let report = try RimWorldAnalyzer().analyze(
            save: saveURL,
            modDirectories: [],
            config: nil,
            log: nil
        )

        XCTAssertTrue(report.structuralIssues.contains {
            $0.objectId == "Human42" && $0.problem == "duplicate (2×)"
        })
        XCTAssertTrue(report.structuralIssues.contains {
            $0.objectId == "Human999" && $0.problem == "target missing (1×)"
        })
    }

    func testAttributesStackTraceToModAssembly() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let modURL = try addMod(
            in: modsURL,
            folder: "CoolMod",
            packageId: "example.cool",
            name: "Cool Mod"
        )
        let assembliesURL = modURL.appendingPathComponent("Assemblies", isDirectory: true)
        try FileManager.default.createDirectory(at: assembliesURL, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: assembliesURL.appendingPathComponent("CoolFeature.dll").path,
            contents: Data()
        )
        let logURL = root.appendingPathComponent("Player.log")
        try write(
            "Error while patching a method\n  at CoolFeature.Startup.ApplyPatch()\n",
            to: logURL
        )

        let report = try RimWorldAnalyzer().analyze(
            save: saveURL,
            modDirectories: [modsURL],
            config: nil,
            log: logURL
        )

        XCTAssertEqual(report.logIssues.first?.relatedMods.first?.packageId, "example.cool")
        XCTAssertEqual(report.logIssues.first?.confidence, "средняя")
    }

    func testModeRemoverKeepsForeignReferences() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let modURL = try addMod(
            in: modsURL,
            folder: "OwnedOnly",
            packageId: "Example.Owned",
            name: "Owned Only"
        )
        let defsURL = modURL.appendingPathComponent("Defs", isDirectory: true)
        try FileManager.default.createDirectory(at: defsURL, withIntermediateDirectories: true)
        try write(
            """
            <Defs>
              <ThingDef>
                <defName>MySword</defName>
                <stuffCategories>
                  <li>Metallic</li>
                </stuffCategories>
                <costList>
                  <Steel>25</Steel>
                  <SomeOtherModDef>1</SomeOtherModDef>
                </costList>
                <tools>
                  <li><capacities><li>Bite</li><li>Scratch</li></capacities></li>
                </tools>
              </ThingDef>
            </Defs>
            """,
            to: defsURL.appendingPathComponent("Items.xml")
        )
        try write(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <savegame>
              <meta>
                <gameVersion>1.6.4500</gameVersion>
                <modNames><li>Owned Only</li></modNames>
                <modIds><li>example.owned</li></modIds>
              </meta>
              <game>
                <things>
                  <thing Class="ThingWithComps"><def>MySword</def><id>MySword1</id></thing>
                  <thing Class="ThingWithComps"><def>Steel</def><id>Steel1</id></thing>
                  <thing Class="ThingWithComps"><def>SomeOtherModDef</def><id>Other1</id></thing>
                  <thing Class="MinifiedThing">
                    <def>MinifiedThing</def>
                    <id>MinifiedThingRadiology1</id>
                    <innerContainer>
                      <innerList>
                        <li Class="Building"><def>MySword</def><id>MySwordMinified1</id></li>
                      </innerList>
                    </innerContainer>
                  </thing>
                  <thing Class="MinifiedThing">
                    <def>MinifiedThing</def>
                    <id>MinifiedThingSteel1</id>
                    <innerContainer>
                      <innerList>
                        <li Class="Building"><def>Steel</def><id>SteelMinified1</id></li>
                      </innerList>
                    </innerContainer>
                  </thing>
                </things>
                <allowedStuff>
                  <li>Metallic</li>
                </allowedStuff>
                <injuries>
                  <li Class="Hediff_Injury"><def>Bite</def><source>Human</source></li>
                  <li Class="Hediff_Injury"><def>Scratch</def><source>Human</source></li>
                </injuries>
                <lookup>
                  <keys><li>removedPair</li><li>keptPair</li></keys>
                  <values><li>MySword</li><li>Steel</li></values>
                </lookup>
              </game>
            </savegame>
            """,
            to: saveURL
        )

        let scan = try ModRemovalService().scan(saveURL: saveURL, modURL: modURL)
        XCTAssertEqual(scan.defCount, 4)
        XCTAssertEqual(scan.matchedDefCount, 1)
        XCTAssertGreaterThanOrEqual(scan.foreignReferenceCount, 3)
        XCTAssertTrue(scan.planItems.contains { $0.category == "Foreign references" })
        XCTAssertFalse(scan.previewItems?.contains { ["Bite", "Scratch"].contains($0.subject) } == true)

        let report = try ModRemovalService().clean(saveURL: saveURL, modURL: modURL)
        let outputPath = try XCTUnwrap(report.outputPath)
        let original = try String(contentsOf: saveURL)
        let cleaned = try String(contentsOf: URL(fileURLWithPath: outputPath))

        XCTAssertNil(report.backupPath)
        XCTAssertTrue(outputPath.hasSuffix("Colony [cleaned].rws"))
        XCTAssertTrue(original.contains("<def>MySword</def>"))
        XCTAssertTrue(original.contains("<li>example.owned</li>"))
        XCTAssertFalse(cleaned.contains("<def>MySword</def>"))
        XCTAssertFalse(cleaned.contains("MinifiedThingRadiology1"))
        XCTAssertTrue(cleaned.contains("MinifiedThingSteel1"))
        XCTAssertTrue(cleaned.contains("SteelMinified1"))
        XCTAssertTrue(cleaned.contains("<li>example.owned</li>"))
        XCTAssertTrue(cleaned.contains("<li>Owned Only</li>"))
        XCTAssertTrue(cleaned.contains("<def>Steel</def>"))
        XCTAssertTrue(cleaned.contains("<def>SomeOtherModDef</def>"))
        XCTAssertTrue(cleaned.contains("<li>Metallic</li>"))
        XCTAssertTrue(cleaned.contains("<def>Bite</def>"))
        XCTAssertTrue(cleaned.contains("<def>Scratch</def>"))
        XCTAssertFalse(cleaned.contains("<li>removedPair</li>"))
        XCTAssertTrue(cleaned.contains("<li>keptPair</li>"))
        let cleanedDocument = try XMLDocument(contentsOf: URL(fileURLWithPath: outputPath))
        let dictionaryKeys = try cleanedDocument.nodes(forXPath: "/savegame/game/lookup/keys/li")
        let dictionaryValues = try cleanedDocument.nodes(forXPath: "/savegame/game/lookup/values/li")
        XCTAssertEqual(dictionaryKeys.count, 1)
        XCTAssertEqual(dictionaryKeys.count, dictionaryValues.count)

        try "stale cleaned content".write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
        let secondReport = try ModRemovalService().clean(saveURL: saveURL, modURL: modURL, removeMetadata: true)
        let secondOutputPath = try XCTUnwrap(secondReport.outputPath)
        let secondCleaned = try String(contentsOf: URL(fileURLWithPath: secondOutputPath))
        let numberedOutput = saveURL.deletingLastPathComponent().appendingPathComponent("Colony [cleaned] 2.rws")

        XCTAssertEqual(secondOutputPath, outputPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: numberedOutput.path))
        XCTAssertFalse(secondCleaned.contains("stale cleaned content"))
        XCTAssertFalse(secondCleaned.contains("<def>MySword</def>"))
        XCTAssertFalse(secondCleaned.contains("<li>example.owned</li>"))
        XCTAssertFalse(secondCleaned.contains("<li>Owned Only</li>"))
    }

    func testModRemovalCleansMultipleModsInOnePass() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let firstMod = try addMod(in: modsURL, folder: "First", packageId: "example.first", name: "First Mod")
        let secondMod = try addMod(in: modsURL, folder: "Second", packageId: "example.second", name: "Second Mod")
        let firstDefs = firstMod.appendingPathComponent("Defs", isDirectory: true)
        let secondDefs = secondMod.appendingPathComponent("Defs", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDefs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDefs, withIntermediateDirectories: true)
        try write("<Defs><ThingDef><defName>FirstThing</defName></ThingDef></Defs>", to: firstDefs.appendingPathComponent("Defs.xml"))
        try write("<Defs><ThingDef><defName>SecondThing</defName></ThingDef></Defs>", to: secondDefs.appendingPathComponent("Defs.xml"))
        try write(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <savegame>
              <meta>
                <modNames><li>First Mod</li><li>Second Mod</li></modNames>
                <modIds><li>example.first</li><li>example.second</li></modIds>
              </meta>
              <game>
                <things>
                  <thing><def>FirstThing</def></thing>
                  <thing><def>SecondThing</def></thing>
                  <thing><def>Steel</def></thing>
                </things>
              </game>
            </savegame>
            """,
            to: saveURL
        )

        let report = try ModRemovalService().clean(saveURL: saveURL, modURLs: [firstMod, secondMod], removeMetadata: true)
        let cleaned = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(report.outputPath)))

        XCTAssertEqual(Set(report.packageIds ?? []), ["example.first", "example.second"])
        XCTAssertEqual(report.matchedDefCount, 2)
        XCTAssertFalse(cleaned.contains("FirstThing"))
        XCTAssertFalse(cleaned.contains("SecondThing"))
        XCTAssertFalse(cleaned.contains("example.first"))
        XCTAssertFalse(cleaned.contains("example.second"))
        XCTAssertTrue(cleaned.contains("Steel"))
    }

    func testModRemovalDeletesCustomWorkTypePrioritySlotWithoutShiftingLaterWorkTypes() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let core = try addMod(in: modsURL, folder: "Core", packageId: "ludeon.rimworld", name: "Core")
        let earlier = try addMod(in: modsURL, folder: "Earlier", packageId: "example.earlier", name: "Earlier")
        let removed = try addMod(in: modsURL, folder: "Removed", packageId: "example.removed", name: "Removed")
        let later = try addMod(in: modsURL, folder: "Later", packageId: "example.later", name: "Later")

        for (mod, defs) in [
            (core, ["Firefighter", "Doctor"]),
            (earlier, ["EarlierWork"]),
            (removed, ["RemovedWork"]),
            (later, ["LaterWork"])
        ] {
            let defsURL = mod.appendingPathComponent("Defs/WorkTypeDefs", isDirectory: true)
            try FileManager.default.createDirectory(at: defsURL, withIntermediateDirectories: true)
            let xml = defs.map { "<WorkTypeDef><defName>\($0)</defName></WorkTypeDef>" }.joined()
            try write("<Defs>\(xml)</Defs>", to: defsURL.appendingPathComponent("WorkTypes.xml"))
        }

        try write(
            """
            <savegame>
              <meta>
                <gameVersion>1.6.4500</gameVersion>
                <modIds>
                  <li>ludeon.rimworld</li><li>example.earlier</li>
                  <li>example.removed</li><li>example.later</li>
                </modIds>
              </meta>
              <game><pawns>
                <li><def>Human</def><workSettings><priorities><vals>
                  <li>1</li><li>2</li><li>3</li><li>4</li><li>5</li>
                </vals></priorities></workSettings></li>
                <li><def>Human</def><workSettings><priorities><vals>
                  <li>1</li><li>2</li><li>3</li>
                </vals></priorities></workSettings></li>
              </pawns></game>
            </savegame>
            """,
            to: saveURL
        )

        let report = try ModRemovalService().clean(
            saveURL: saveURL,
            modURLs: [removed],
            protectedModURLs: [core, earlier, later]
        )
        let cleanedURL = URL(fileURLWithPath: try XCTUnwrap(report.outputPath))
        let document = try XMLDocument(contentsOf: cleanedURL)
        let priorityLists = try document.nodes(forXPath: "//workSettings/priorities/vals")

        XCTAssertEqual(priorityLists.count, 2)
        XCTAssertEqual(priorityLists[0].children?.compactMap(\.stringValue), ["1", "2", "3", "5"])
        XCTAssertEqual(priorityLists[1].children?.compactMap(\.stringValue), ["1", "2", "3"])
        XCTAssertTrue(report.planItems.contains {
            $0.subject == "Pawn work priorities" && $0.count == 1
        })
    }

    func testModRemovalKeepsDefsOwnedByProtectedActiveMods() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let inactiveAddon = try addMod(in: modsURL, folder: "InactiveAddon", packageId: "example.inactive", name: "Inactive Addon")
        let activeMod = try addMod(in: modsURL, folder: "ActiveOwner", packageId: "example.active", name: "Active Owner")
        for mod in [inactiveAddon, activeMod] {
            let defs = mod.appendingPathComponent("Defs", isDirectory: true)
            try FileManager.default.createDirectory(at: defs, withIntermediateDirectories: true)
            try write("<Defs><ThingDef><defName>SharedThing</defName></ThingDef></Defs>", to: defs.appendingPathComponent("Defs.xml"))
        }
        try write(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <savegame><meta /><game><things><thing><def>SharedThing</def></thing></things></game></savegame>
            """,
            to: saveURL
        )

        let report = try ModRemovalService().clean(saveURL: saveURL, modURLs: [inactiveAddon], protectedModURLs: [activeMod])
        let cleaned = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(report.outputPath)))

        XCTAssertEqual(report.matchedDefCount, 0)
        XCTAssertTrue(cleaned.contains("SharedThing"))
    }

    func testModRemovalKeepsProtectedHediffWhenThingDefSharesItsName() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let removedMod = try addMod(in: modsURL, folder: "Removed", packageId: "example.removed", name: "Removed Mod")
        let protectedMod = try addMod(in: modsURL, folder: "Protected", packageId: "example.protected", name: "Protected Mod")
        let removedDefs = removedMod.appendingPathComponent("Defs", isDirectory: true)
        let protectedDefs = protectedMod.appendingPathComponent("Defs", isDirectory: true)
        try FileManager.default.createDirectory(at: removedDefs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: protectedDefs, withIntermediateDirectories: true)
        try write("<Defs><ThingDef><defName>FleshmassLung</defName></ThingDef></Defs>", to: removedDefs.appendingPathComponent("Defs.xml"))
        try write("<Defs><HediffDef><defName>FleshmassLung</defName></HediffDef></Defs>", to: protectedDefs.appendingPathComponent("Defs.xml"))
        try write(
            """
            <savegame><meta /><game>
              <priceModifiers><keys><li>FleshmassLung</li><li>Steel</li></keys><values><li>2</li><li>3</li></values></priceModifiers>
              <priceHistoryRecorders><keys><li>FleshmassLung</li><li>Steel</li></keys><values><li>old</li><li>kept</li></values></priceHistoryRecorders>
              <health><hediffs><li Class="Hediff_AddedPart"><loadID>8</loadID><def>FleshmassLung</def></li></hediffs></health>
              <things><thing><def>FleshmassLung</def><id>FleshmassLung17</id></thing></things>
            </game></savegame>
            """,
            to: saveURL
        )

        let report = try ModRemovalService().clean(saveURL: saveURL, modURLs: [removedMod], protectedModURLs: [protectedMod])
        let document = try XMLDocument(contentsOf: URL(fileURLWithPath: try XCTUnwrap(report.outputPath)))
        XCTAssertEqual(try document.nodes(forXPath: "/savegame/game/priceModifiers/keys/li").compactMap(\.stringValue), ["Steel"])
        XCTAssertEqual(try document.nodes(forXPath: "/savegame/game/priceModifiers/values/li").compactMap(\.stringValue), ["3"])
        XCTAssertEqual(try document.nodes(forXPath: "/savegame/game/priceHistoryRecorders/keys/li").compactMap(\.stringValue), ["Steel"])
        XCTAssertEqual(try document.nodes(forXPath: "/savegame/game/health/hediffs/li/def").first?.stringValue, "FleshmassLung")
        XCTAssertTrue(try document.nodes(forXPath: "/savegame/game/things/thing").isEmpty)
    }

    func testModRemovalRemovesStalePawnDietEntryForSelectedRace() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let removedMod = try addMod(in: modsURL, folder: "Removed", packageId: "example.removed", name: "Removed Mod")
        let defsURL = removedMod.appendingPathComponent("Defs", isDirectory: true)
        try FileManager.default.createDirectory(at: defsURL, withIntermediateDirectories: true)
        try write("<Defs><ThingDef><defName>FH_Whipspike</defName><race /></ThingDef></Defs>", to: defsURL.appendingPathComponent("Defs.xml"))
        try write(
            """
            <savegame><meta /><game>
              <pawns><li Class="Pawn"><def>Human</def><id>Human1</id><kindDef>Colonist</kindDef></li></pawns>
              <diets><li><pawn>Thing_FH_Whipspike8480079</pawn><favourites><li>MealSurvivalPack</li></favourites></li>
                <li><pawn>Thing_Human1</pawn><favourites><li>MealSimple</li></favourites></li></diets>
            </game></savegame>
            """,
            to: saveURL
        )

        let report = try ModRemovalService().clean(saveURL: saveURL, modURL: removedMod)
        let document = try XMLDocument(contentsOf: URL(fileURLWithPath: try XCTUnwrap(report.outputPath)))
        XCTAssertEqual(try document.nodes(forXPath: "/savegame/game/diets/li/pawn").compactMap(\.stringValue), ["Thing_Human1"])
    }

    func testModRemovalRestoresPawnWithRemovedMutantType() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let removedMod = try addMod(in: modsURL, folder: "Removed", packageId: "example.removed", name: "Removed Mod")
        let defsURL = removedMod.appendingPathComponent("Defs", isDirectory: true)
        try FileManager.default.createDirectory(at: defsURL, withIntermediateDirectories: true)
        try write("<Defs><Custom.MutantDef><defName>ModMutant</defName></Custom.MutantDef></Defs>", to: defsURL.appendingPathComponent("Mutants.xml"))
        try write(
            """
            <savegame><meta /><game><pawns>
              <li Class="Pawn"><def>Human</def><id>Human1</id><kindDef>Colonist</kindDef>
                <shambler><shamblerType>ModMutant</shamblerType><hasTurned>True</hasTurned>
                  <mutantHediff>Hediff_99</mutantHediff><verbTracker><verbs /></verbTracker></shambler>
                <genes><endogenes><li><def>Robust</def><pawn>Thing_Human1</pawn><loadID>7</loadID></li></endogenes></genes>
              </li>
              <li Class="Pawn"><def>Human</def><id>Human2</id><kindDef>Colonist</kindDef>
                <shambler><shamblerType>Shambler</shamblerType><hasTurned>True</hasTurned></shambler>
              </li>
            </pawns></game></savegame>
            """,
            to: saveURL
        )

        let report = try ModRemovalService().clean(saveURL: saveURL, modURL: removedMod)
        let document = try XMLDocument(contentsOf: URL(fileURLWithPath: try XCTUnwrap(report.outputPath)))
        XCTAssertEqual(try document.nodes(forXPath: "//li[id='Human1']/shambler/@IsNull").first?.stringValue, "True")
        XCTAssertTrue(try document.nodes(forXPath: "//li[id='Human1']/shambler/*").isEmpty)
        XCTAssertEqual(try document.nodes(forXPath: "//li[id='Human1']/genes/endogenes/li/def").first?.stringValue, "Robust")
        XCTAssertEqual(try document.nodes(forXPath: "//li[id='Human2']/shambler/shamblerType").first?.stringValue, "Shambler")
        XCTAssertTrue(report.planItems.contains { $0.subject == "Pawn mutant states cleared" && $0.count == 1 })
    }

    func testModRemovalAlwaysProtectsOfficialDefsWithoutConfig() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let selectedMod = try addMod(in: modsURL, folder: "Selected", packageId: "example.selected", name: "Selected Mod")
        let selectedDefs = selectedMod.appendingPathComponent("Defs", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedDefs, withIntermediateDirectories: true)
        try write(
            "<Defs><ThingDef><defName>Bite</defName></ThingDef></Defs>",
            to: selectedDefs.appendingPathComponent("Defs.xml")
        )

        let dataURL = root.appendingPathComponent("Data", isDirectory: true)
        let coreURL = try addMod(in: dataURL, folder: "Core", packageId: "Ludeon.RimWorld", name: "Core")
        let coreDefs = coreURL.appendingPathComponent("Defs", isDirectory: true)
        try FileManager.default.createDirectory(at: coreDefs, withIntermediateDirectories: true)
        try write(
            "<Defs><HediffDef><defName>Bite</defName></HediffDef></Defs>",
            to: coreDefs.appendingPathComponent("Defs.xml")
        )
        try write(
            "<savegame><meta /><game><injuries><li><def>Bite</def><source>Human</source></li></injuries></game></savegame>",
            to: saveURL
        )

        let protectedURLs = ModRemovalService.activeProtectionURLs(
            configURL: nil,
            modURLs: [modsURL],
            selectedModURLs: [selectedMod]
        )
        XCTAssertEqual(
            protectedURLs.map { $0.resolvingSymlinksInPath().path },
            [coreURL.resolvingSymlinksInPath().path]
        )

        let report = try ModRemovalService().clean(
            saveURL: saveURL,
            modURLs: [selectedMod],
            protectedModURLs: protectedURLs
        )
        let cleaned = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(report.outputPath)))

        XCTAssertEqual(report.matchedDefCount, 0)
        XCTAssertTrue(cleaned.contains("<def>Bite</def>"))
        XCTAssertTrue(cleaned.contains("<source>Human</source>"))
    }

    func testModRemovalPreservesVanillaInjuryCausedByRemovedModThing() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let removedMod = try addMod(
            in: modsURL,
            folder: "HousekeeperCat",
            packageId: "example.housekeepercat",
            name: "Housekeeper Cat"
        )
        let defsURL = removedMod.appendingPathComponent("Defs", isDirectory: true)
        try FileManager.default.createDirectory(at: defsURL, withIntermediateDirectories: true)
        try write(
            "<Defs><ThingDef><defName>HousekeeperCat</defName></ThingDef></Defs>",
            to: defsURL.appendingPathComponent("Races.xml")
        )
        try write(
            """
            <savegame><meta /><game><injuries>
              <li Class="Hediff_Injury">
                <loadID>11779</loadID>
                <def>Bite</def>
                <source>HousekeeperCat</source>
                <severity>6</severity>
              </li>
            </injuries></game></savegame>
            """,
            to: saveURL
        )

        let scan = try ModRemovalService().scan(saveURL: saveURL, modURL: removedMod)
        let previewItems = scan.previewItems ?? []

        XCTAssertFalse(previewItems.contains {
            $0.entity == "Things and items" && $0.subject == "Bite"
        })
        XCTAssertTrue(previewItems.contains {
            $0.entity == "Scalar references"
                && $0.subject == "source: HousekeeperCat"
                && $0.replacement == "null"
        })

        let report = try ModRemovalService().clean(saveURL: saveURL, modURL: removedMod)
        let cleaned = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(report.outputPath)))

        XCTAssertTrue(cleaned.contains("<def>Bite</def>"))
        XCTAssertTrue(cleaned.contains("<severity>6</severity>"))
        XCTAssertTrue(cleaned.contains("<source>null</source>"))
    }

    func testModRemovalClearsRemovedCurrentJobWithoutRemovingPawn() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let removedMod = try addMod(
            in: modsURL,
            folder: "TrainingFacility",
            packageId: "example.trainingfacility",
            name: "Training Facility"
        )
        let defsURL = removedMod.appendingPathComponent("Defs", isDirectory: true)
        let assembliesURL = removedMod.appendingPathComponent("Assemblies", isDirectory: true)
        try FileManager.default.createDirectory(at: defsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assembliesURL, withIntermediateDirectories: true)
        try write(
            "<Defs><JobDef><defName>UseMartialArtsTarget</defName></JobDef></Defs>",
            to: defsURL.appendingPathComponent("Jobs.xml")
        )
        try managedAssembly(typeNames: [("TrainingFacility", "JobDriver_MartialArtsTarget")])
            .write(to: assembliesURL.appendingPathComponent("TrainingFacility.dll"))
        try write(
            """
            <savegame><meta /><game><pawns><li Class="Pawn">
              <def>Human</def><id>Human5851940</id><name><first>Камиса</first></name>
              <jobs>
                <curJob><loadID>Job_4693195</loadID><def>UseMartialArtsTarget</def><targetA>Thing_MartialArtsTarget7556883</targetA></curJob>
                <curDriver Class="TrainingFacility.JobDriver_MartialArtsTarget"><pawn>Thing_Human5851940</pawn></curDriver>
              </jobs>
            </li></pawns></game></savegame>
            """,
            to: saveURL
        )

        let scan = try ModRemovalService().scan(saveURL: saveURL, modURL: removedMod)
        let previewItems = try XCTUnwrap(scan.previewItems)
        XCTAssertTrue(previewItems.contains {
            $0.entity == "Pawn current jobs"
                && $0.subject == "UseMartialArtsTarget"
                && $0.action == "clear"
        })
        XCTAssertFalse(previewItems.contains {
            $0.entity == "Owned serialized classes"
                && $0.subject == "TrainingFacility.JobDriver_MartialArtsTarget"
        })

        let report = try ModRemovalService().clean(saveURL: saveURL, modURL: removedMod)
        let cleanedURL = URL(fileURLWithPath: try XCTUnwrap(report.outputPath))
        let cleaned = try String(contentsOf: cleanedURL)
        let document = try XMLDocument(contentsOf: cleanedURL, options: [])

        XCTAssertNotNil(document.rootElement())
        XCTAssertTrue(cleaned.contains("<id>Human5851940</id>"))
        XCTAssertTrue(cleaned.contains("<first>Камиса</first>"))
        XCTAssertFalse(cleaned.contains("<curJob>"))
        XCTAssertFalse(cleaned.contains("<curDriver"))
        XCTAssertFalse(cleaned.contains("UseMartialArtsTarget"))
        XCTAssertFalse(cleaned.contains("TrainingFacility.JobDriver_MartialArtsTarget"))
    }

    func testModRemovalPreservesObjectsMadeFromRemovedModStuff() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let removedMod = try addMod(
            in: modsURL,
            folder: "HousekeeperCat",
            packageId: "example.housekeepercat",
            name: "Housekeeper Cat"
        )
        let defsURL = removedMod.appendingPathComponent("Defs", isDirectory: true)
        try FileManager.default.createDirectory(at: defsURL, withIntermediateDirectories: true)
        try write(
            "<Defs><ThingDef><defName>Leather_HKCat</defName></ThingDef></Defs>",
            to: defsURL.appendingPathComponent("Items.xml")
        )
        try write(
            """
            <savegame><meta /><game>
              <things><li><def>Apparel_BowlerHat</def><id>Hat1</id><stuff>Leather_HKCat</stuff></li></things>
              <precepts><li Class="Precept_Relic"><name>Relic name</name><def>IdeoRelic</def><thingDef>Apparel_KidPants</thingDef><stuff>Leather_HKCat</stuff></li></precepts>
            </game></savegame>
            """,
            to: saveURL
        )

        let scan = try ModRemovalService().scan(saveURL: saveURL, modURL: removedMod)
        let previewItems = scan.previewItems ?? []

        XCTAssertFalse(previewItems.contains {
            $0.entity == "Things and items"
                && ["Apparel_BowlerHat", "IdeoRelic"].contains($0.subject)
        })
        XCTAssertTrue(previewItems.contains {
            $0.entity == "Stuff"
                && $0.subject == "Leather_HKCat"
                && $0.replacement == "Cloth"
                && $0.count == 2
        })

        let report = try ModRemovalService().clean(saveURL: saveURL, modURL: removedMod)
        let cleaned = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(report.outputPath)))

        XCTAssertTrue(cleaned.contains("<def>Apparel_BowlerHat</def>"))
        XCTAssertTrue(cleaned.contains("<id>Hat1</id>"))
        XCTAssertTrue(cleaned.contains("<def>IdeoRelic</def>"))
        XCTAssertTrue(cleaned.contains("<name>Relic name</name>"))
        XCTAssertEqual(cleaned.components(separatedBy: "<stuff>Cloth</stuff>").count - 1, 2)
        XCTAssertFalse(cleaned.contains("Leather_HKCat"))
    }

    func testModRemovalDoesNotTreatBodyPartIndexAsRemovedObjectReference() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let removedMod = try addMod(
            in: modsURL,
            folder: "Removed",
            packageId: "example.removed",
            name: "Removed Mod"
        )
        let defsURL = removedMod.appendingPathComponent("Defs", isDirectory: true)
        try FileManager.default.createDirectory(at: defsURL, withIntermediateDirectories: true)
        try write(
            "<Defs><ThingDef><defName>RemovedThing</defName></ThingDef></Defs>",
            to: defsURL.appendingPathComponent("Things.xml")
        )
        try write(
            """
            <savegame><meta /><game>
              <things><li><loadID>34</loadID><def>RemovedThing</def></li></things>
              <pawns><li Class="Pawn"><def>Human</def><id>Human1</id><health><hediffSet><hediffs>
                <li Class="Hediff_AddedPart"><loadID>900</loadID><def>BionicArm</def><part><body>Human</body><index>34</index></part></li>
              </hediffs></hediffSet></health></li></pawns>
              <trackedObject>Thing_34</trackedObject>
            </game></savegame>
            """,
            to: saveURL
        )

        let report = try ModRemovalService().clean(saveURL: saveURL, modURL: removedMod)
        let cleaned = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(report.outputPath)))

        XCTAssertFalse(cleaned.contains("RemovedThing"))
        XCTAssertTrue(cleaned.contains("<def>BionicArm</def>"))
        XCTAssertTrue(cleaned.contains("<index>34</index>"))
        XCTAssertFalse(cleaned.contains("<index>null</index>"))
        XCTAssertTrue(cleaned.contains("<trackedObject>null</trackedObject>"))
    }

    func testModRemovalDeletesAnimalsWhosePawnKindComesFromRemovedMod() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let removedMod = try addMod(in: modsURL, folder: "Removed", packageId: "example.removed", name: "Removed Mod")
        let defsURL = removedMod.appendingPathComponent("Defs", isDirectory: true)
        try FileManager.default.createDirectory(at: defsURL, withIntermediateDirectories: true)
        try write(
            "<Defs><PawnKindDef><defName>RemovedAnimalKind</defName></PawnKindDef></Defs>",
            to: defsURL.appendingPathComponent("Defs.xml")
        )
        try write(
            """
            <savegame><meta /><game>
              <pawns><li Class="Pawn"><def>Alpaca</def><id>Animal1</id><kindDef>RemovedAnimalKind</kindDef></li></pawns>
              <targets><li>Thing_Animal1</li><selectedPawn>Animal1</selectedPawn></targets>
            </game></savegame>
            """,
            to: saveURL
        )

        let scan = try ModRemovalService().scan(saveURL: saveURL, modURLs: [removedMod])
        let previewItems = try XCTUnwrap(scan.previewItems)
        XCTAssertTrue(previewItems.contains {
            $0.subject == "RemovedAnimalKind" && $0.action == "remove"
        })
        XCTAssertFalse(previewItems.contains {
            $0.subject == "RemovedAnimalKind" && $0.replacement == "Colonist"
        })

        let report = try ModRemovalService().clean(saveURL: saveURL, modURLs: [removedMod])
        let cleaned = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(report.outputPath)))

        XCTAssertFalse(cleaned.contains("Animal1"))
        XCTAssertFalse(cleaned.contains("RemovedAnimalKind"))
        XCTAssertFalse(cleaned.contains("<kindDef>Colonist</kindDef>"))
        XCTAssertTrue(cleaned.contains("<selectedPawn>null</selectedPawn>"))
    }

    func testModRemovalPreservesHumanlikeModPawnAsBaselineHuman() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let removedMod = try addMod(in: modsURL, folder: "Removed", packageId: "example.removed", name: "Removed Mod")
        let defsURL = removedMod.appendingPathComponent("Defs", isDirectory: true)
        try FileManager.default.createDirectory(at: defsURL, withIntermediateDirectories: true)
        try write(
            """
            <Defs>
              <ThingDef><defName>RemovedAlien</defName><race /></ThingDef>
              <PawnKindDef><defName>RemovedAlienKind</defName></PawnKindDef>
              <XenotypeDef><defName>RemovedXenotype</defName></XenotypeDef>
              <GeneDef><defName>RemovedGene</defName></GeneDef>
              <HediffDef><defName>RemovedHediff</defName></HediffDef>
              <BodyTypeDef><defName>RemovedBody</defName></BodyTypeDef>
              <HeadTypeDef><defName>RemovedHead</defName></HeadTypeDef>
              <HairDef><defName>RemovedHair</defName></HairDef>
              <ThingDef><defName>RemovedApparel</defName></ThingDef>
            </Defs>
            """,
            to: defsURL.appendingPathComponent("Defs.xml")
        )
        try write(
            """
            <savegame><meta /><game>
              <pawns><li Class="Pawn">
                <def>RemovedAlien</def><id>Alien1</id><kindDef>RemovedAlienKind</kindDef><gender>Female</gender>
                <name><first>Ada</first><nick>Ada</nick><last>Lovelace</last></name>
                <story><bodyType>RemovedBody</bodyType><headType>RemovedHead</headType><hairDef>RemovedHair</hairDef></story>
                <skills><skills><li><def>Intellectual</def><level>14</level></li></skills></skills>
                <genes><endogenes><li><def>RemovedGene</def><loadID>7</loadID></li></endogenes><xenogenes /><xenotype>RemovedXenotype</xenotype></genes>
                <health><hediffSet><hediffs><li Class="Hediff"><loadID>8</loadID><def>RemovedHediff</def></li></hediffs></hediffSet></health>
                <apparel><wornApparel><innerList><li><def>RemovedApparel</def><id>Apparel1</id></li></innerList></wornApparel></apparel>
              </li></pawns>
              <selection><selectedPawn>Thing_Alien1</selectedPawn></selection>
            </game></savegame>
            """,
            to: saveURL
        )

        let report = try ModRemovalService().clean(saveURL: saveURL, modURL: removedMod)
        let cleanedURL = URL(fileURLWithPath: try XCTUnwrap(report.outputPath))
        let document = try XMLDocument(contentsOf: cleanedURL, options: [])

        XCTAssertEqual(try document.nodes(forXPath: "/savegame/game/pawns/li/def").first?.stringValue, "Human")
        XCTAssertEqual(try document.nodes(forXPath: "/savegame/game/pawns/li/kindDef").first?.stringValue, "Colonist")
        XCTAssertEqual(try document.nodes(forXPath: "/savegame/game/pawns/li/id").first?.stringValue, "Alien1")
        XCTAssertEqual(try document.nodes(forXPath: "/savegame/game/pawns/li/name/nick").first?.stringValue, "Ada")
        XCTAssertEqual(try document.nodes(forXPath: "/savegame/game/pawns/li/skills/skills/li/level").first?.stringValue, "14")
        XCTAssertEqual(try document.nodes(forXPath: "/savegame/game/pawns/li/story/bodyType").first?.stringValue, "Female")
        XCTAssertEqual(try document.nodes(forXPath: "/savegame/game/pawns/li/story/headType").first?.stringValue, "Female_AverageNormal")
        XCTAssertEqual(try document.nodes(forXPath: "/savegame/game/pawns/li/story/hairDef").first?.stringValue, "Shaved")
        XCTAssertEqual(try document.nodes(forXPath: "/savegame/game/pawns/li/genes/xenotype").first?.stringValue, "Baseline")
        XCTAssertEqual(try document.nodes(forXPath: "/savegame/game/selection/selectedPawn").first?.stringValue, "Thing_Alien1")
        XCTAssertTrue(try document.nodes(forXPath: "/savegame/game/pawns/li/genes/endogenes/li").isEmpty)
        XCTAssertTrue(try document.nodes(forXPath: "/savegame/game/pawns/li/health/hediffSet/hediffs/li").isEmpty)
        XCTAssertTrue(try document.nodes(forXPath: "/savegame/game/pawns/li/apparel/wornApparel/innerList/li").isEmpty)
    }

    func testModRemovalCleansGeneratedRaceDefsAndTheirDictionaryValues() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let removedMod = try addMod(in: modsURL, folder: "Removed", packageId: "example.removed", name: "Removed Mod")
        let defsURL = removedMod.appendingPathComponent("Defs", isDirectory: true)
        try FileManager.default.createDirectory(at: defsURL, withIntermediateDirectories: true)
        try write(
            "<Defs><ThingDef><defName>RemovedRace</defName><race /></ThingDef></Defs>",
            to: defsURL.appendingPathComponent("Defs.xml")
        )
        try write(
            """
            <savegame><meta /><game>
              <lookup>
                <keys><li>Corpse_RemovedRace</li><li>Steel</li></keys>
                <values><li>removed value</li><li>kept value</li></values>
              </lookup>
              <things>
                <thing><def>Corpse_RemovedRace</def><id>Corpse1</id></thing>
                <thing><def>Steel</def><id>Steel1</id></thing>
              </things>
            </game></savegame>
            """,
            to: saveURL
        )

        let report = try ModRemovalService().clean(saveURL: saveURL, modURL: removedMod)
        let cleanedURL = URL(fileURLWithPath: try XCTUnwrap(report.outputPath))
        let document = try XMLDocument(contentsOf: cleanedURL, options: [])

        XCTAssertEqual(try document.nodes(forXPath: "/savegame/game/lookup/keys/li").compactMap(\.stringValue), ["Steel"])
        XCTAssertEqual(try document.nodes(forXPath: "/savegame/game/lookup/values/li").compactMap(\.stringValue), ["kept value"])
        XCTAssertEqual(try document.nodes(forXPath: "/savegame/game/things/thing/def").compactMap(\.stringValue), ["Steel"])
    }

    func testModRemovalCleansReferencesToRemovedGenes() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let removedMod = try addMod(in: modsURL, folder: "Removed", packageId: "example.removed", name: "Removed Mod")
        let defsURL = removedMod.appendingPathComponent("Defs", isDirectory: true)
        try FileManager.default.createDirectory(at: defsURL, withIntermediateDirectories: true)
        try write(
            "<Defs><GeneDef><defName>RemovedGene</defName></GeneDef></Defs>",
            to: defsURL.appendingPathComponent("Defs.xml")
        )
        try write(
            """
            <savegame><meta /><game>
              <pawns><li Class="Pawn"><def>Human</def><id>Human1</id><kindDef>Colonist</kindDef><genes>
                <endogenes><li><def>RemovedGene</def><loadID>7</loadID></li></endogenes>
                <xenogenes />
              </genes></li></pawns>
              <tracker><selectedGene>Gene_7</selectedGene><genes><li>Gene_7</li><li>Gene_8</li></genes></tracker>
            </game></savegame>
            """,
            to: saveURL
        )

        let report = try ModRemovalService().clean(saveURL: saveURL, modURL: removedMod)
        let cleaned = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(report.outputPath)))

        XCTAssertFalse(cleaned.contains("RemovedGene"))
        XCTAssertFalse(cleaned.contains("<li>Gene_7</li>"))
        XCTAssertTrue(cleaned.contains("<selectedGene>null</selectedGene>"))
        XCTAssertTrue(cleaned.contains("<li>Gene_8</li>"))
    }

    func testModRemovalRejectsNewPawnIntegrityDamage() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let removedMod = try addMod(in: modsURL, folder: "Removed", packageId: "example.removed", name: "Removed Mod")
        let defsURL = removedMod.appendingPathComponent("Defs", isDirectory: true)
        try FileManager.default.createDirectory(at: defsURL, withIntermediateDirectories: true)
        try write(
            "<Defs><HairDef><defName>RemovedHair</defName></HairDef></Defs>",
            to: defsURL.appendingPathComponent("Defs.xml")
        )
        try write(
            """
            <savegame><meta /><game><pawns><li Class="Pawn">
              <def>Human</def><id>Human1</id><kindDef>Colonist</kindDef>
              <name><first>Ada</first><nick>Ada</nick><last>Lovelace</last></name>
              <story><bodyType>Female</bodyType><headType>Female_AverageNormal</headType><hairDef>RemovedHair</hairDef></story>
            </li></pawns></game></savegame>
            """,
            to: saveURL
        )

        XCTAssertThrowsError(try ModRemovalService().clean(saveURL: saveURL, modURL: removedMod)) { error in
            guard let modRemovalError = error as? ModRemovalError,
                  case let .validationFailed(detail) = modRemovalError else {
                return XCTFail("Expected validation failure, got \(error)")
            }
            XCTAssertTrue(detail.contains("данные пешек"))
        }
        let cleanedURL = root.appendingPathComponent("Colony [cleaned].rws")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanedURL.path))
    }

    func testModRemovalUsesAssemblyOwnershipForUniversalCleanup() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let removedMod = try addMod(in: modsURL, folder: "Removed", packageId: "example.removed", name: "Removed Mod")
        let protectedMod = try addMod(in: modsURL, folder: "Protected", packageId: "example.protected", name: "Protected Mod")

        let removedDefs = removedMod.appendingPathComponent("Defs", isDirectory: true)
        let removedPatches = removedMod.appendingPathComponent("Patches", isDirectory: true)
        let removedAssemblies = removedMod.appendingPathComponent("Assemblies", isDirectory: true)
        let protectedAssemblies = protectedMod.appendingPathComponent("Assemblies", isDirectory: true)
        try FileManager.default.createDirectory(at: removedDefs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: removedPatches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: removedAssemblies, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: protectedAssemblies, withIntermediateDirectories: true)
        try write(
            "<Defs><RecipeDef><defName>RemovedRecipe</defName></RecipeDef><ResearchProjectDef><defName>RemovedResearch</defName></ResearchProjectDef></Defs>",
            to: removedDefs.appendingPathComponent("Defs.xml")
        )
        try write(
            "<Patch><Operation Class=\"PatchOperationAdd\"><xpath>/Defs</xpath><value><ThingDef><defName>PatchCreatedThing</defName></ThingDef></value></Operation></Patch>",
            to: removedPatches.appendingPathComponent("CreatedDefs.xml")
        )
        let removedAssembly = managedAssembly(typeNames: [
            ("Example", "OwnedComponent"),
            ("Example", "CustomPawn"),
            ("Example", "SharedComponent")
        ])
        XCTAssertEqual(ManagedAssemblyTypeReader.typeNames(in: removedAssembly), Set([
            "Example.OwnedComponent", "Example.CustomPawn", "Example.SharedComponent"
        ]))
        try removedAssembly.write(to: removedAssemblies.appendingPathComponent("Removed.dll"))
        try managedAssembly(typeNames: [("Example", "SharedComponent")])
            .write(to: protectedAssemblies.appendingPathComponent("Protected.dll"))

        try write(
            """
            <savegame><meta /><game>
              <components>
                <li Class="Example.OwnedComponent"><id>OwnedComponent1</id></li>
                <li Class="Example.SharedComponent"><id>SharedComponent1</id></li>
              </components>
              <pawns><li Class="Example.CustomPawn"><def>Human</def><id>Human1</id></li></pawns>
              <bills><li Class="Bill_Production"><recipe>RemovedRecipe</recipe><loadID>Bill_1</loadID></li></bills>
              <things><thing><def>PatchCreatedThing</def><id>PatchCreatedThing1</id></thing></things>
              <researchManager><currentProj>RemovedResearch</currentProj></researchManager>
              <targets><li>Thing_OwnedComponent1</li><li>Thing_SharedComponent1</li></targets>
            </game></savegame>
            """,
            to: saveURL
        )

        let report = try ModRemovalService().clean(
            saveURL: saveURL,
            modURLs: [removedMod],
            protectedModURLs: [protectedMod]
        )
        let cleaned = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(report.outputPath)))

        XCTAssertFalse(cleaned.contains("Example.OwnedComponent"))
        XCTAssertFalse(cleaned.contains("OwnedComponent1"))
        XCTAssertFalse(cleaned.contains("Thing_OwnedComponent1"))
        XCTAssertTrue(cleaned.contains("Example.SharedComponent"))
        XCTAssertTrue(cleaned.contains("Thing_SharedComponent1"))
        XCTAssertTrue(cleaned.contains("Class=\"Pawn\""))
        XCTAssertFalse(cleaned.contains("Example.CustomPawn"))
        XCTAssertFalse(cleaned.contains("RemovedRecipe"))
        XCTAssertFalse(cleaned.contains("PatchCreatedThing"))
        XCTAssertTrue(cleaned.contains("<currentProj>null</currentProj>"))
    }

    func testSaveCleanerRemovesUnknownDefsUsingActiveCatalog() throws {
        let modsURL = root.appendingPathComponent("Mods", isDirectory: true)
        let dataURL = root.appendingPathComponent("Data/Core/Defs", isDirectory: true)
        let languageURL = root.appendingPathComponent("Data/Core/Languages/English/DefInjected/ThingDef", isDirectory: true)
        let activeMod = try addMod(in: modsURL, folder: "Active", packageId: "example.active", name: "Active Mod")
        let activeDefs = activeMod.appendingPathComponent("Defs", isDirectory: true)
        let activePatches = activeMod.appendingPathComponent("Patches", isDirectory: true)
        let activeSource = activeMod.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: activeDefs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: activePatches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: activeSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: languageURL, withIntermediateDirectories: true)
        try write(
            "<Defs><ThingDef><defName>KnownThing</defName></ThingDef><ThingDef><defName>VEE_Mangrove</defName></ThingDef><ThingDef><defName>VWE_Gun_SMG</defName></ThingDef><AbilityDef><defName>VPE_FiringFocus</defName></AbilityDef><ResearchProjectDef><defName>KnownResearch</defName></ResearchProjectDef><GeneDef><defName>Learning_Fast</defName></GeneDef><GeneDef><defName>rjw_genes_genetic_disease_immunity</defName></GeneDef><GeneDef><defName>VREStarjack_Gene_Randomizer</defName></GeneDef><VREHussars.WeaponGeneTemplateDef><defName>VREHT_WeaponAptitude</defName></VREHussars.WeaponGeneTemplateDef></Defs>",
            to: activeDefs.appendingPathComponent("Defs.xml")
        )
        try write(
            #"let defName = "Seed_" + thingDef.defName"#,
            to: activeSource.appendingPathComponent("GeneratedDefs.cs")
        )
        try write(
            "<Defs><ThingDef><defName>Human</defName></ThingDef><ThingDef><defName>Alpaca</defName></ThingDef><PawnKindDef><defName>Colonist</defName></PawnKindDef><XenotypeDef><defName>Baseline</defName><genes><li>AptitudePoor_Animals</li><li>ChemicalDependency_GoJuice</li></genes></XenotypeDef><ThingDef><defName>Synthread</defName></ThingDef><ThingSetMakerDef><defName>KnownRewards</defName><fixedParams><thingSetMakerTags><li>Neurotrainer_Animals</li></thingSetMakerTags></fixedParams></ThingSetMakerDef></Defs>",
            to: dataURL.appendingPathComponent("CoreDefs.xml")
        )
        try write(
            "<LanguageData><Corpse_Alpaca.label>alpaca corpse</Corpse_Alpaca.label><Meat_Alpaca.label>alpaca meat</Meat_Alpaca.label></LanguageData>",
            to: languageURL.appendingPathComponent("ImpliedDefs.xml")
        )
        try write(
            "<Patch><Operation Class=\"PatchOperationAdd\"><xpath>/Defs</xpath><value><GeneDef><defName>PatchedGene</defName></GeneDef></value></Operation><Operation Class=\"PatchOperationAdd\"><xpath>Defs</xpath><value><ThingDef><defName>PatchedThing</defName></ThingDef></value></Operation></Patch>",
            to: activePatches.appendingPathComponent("PatchDefs.xml")
        )
        let configURL = root.appendingPathComponent("ModsConfig.xml")
        try write("<ModsConfigData><activeMods><li>example.active</li></activeMods></ModsConfigData>", to: configURL)
        try write(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <savegame>
              <meta />
              <game>
                <things>
                  <thing><def>KnownThing</def><id>Known1</id></thing>
                  <thing><def>Psytrainer_VPE_FiringFocus</def><id>Psytrainer1</id></thing>
                  <thing><def>Psytrainer_OldAbility</def><id>Psytrainer2</id></thing>
                  <thing><def>Techprint_KnownResearch</def><id>Techprint1</id></thing>
                  <thing><def>PatchedGene</def><id>Patched1</id></thing>
                  <thing><def>PatchedThing</def><id>Patched2</id></thing>
                  <thing><def>Seed_VEE_Mangrove</def><id>Seed1</id></thing>
                  <thing><def>Corpse_Alpaca</def><id>Corpse1</id></thing>
                  <thing><def>Meat_Alpaca</def><id>Meat1</id></thing>
                  <thing><def>Neurotrainer_Animals</def><id>Neurotrainer1</id></thing>
                  <thing><def>OldThing</def><id>Old1</id></thing>
                </things>
                <records>
                  <li>
                    <recorder>
                      <thingDef>Company_0</thingDef>
                    </recorder>
                  </li>
                  <li>
                    <recorder>
                      <thingDef>OldThing</thingDef>
                    </recorder>
                  </li>
                  <li>
                    <recordsDeflate>abc</recordsDeflate>
                    <thingDef>OldThing</thingDef>
                  </li>
                </records>
                <pawns>
                  <li Class="Pawn">
                    <def>Alpaca</def>
                    <id>Animal1</id>
                    <kindDef>OldAnimalKind</kindDef>
                  </li>
                  <li Class="Pawn">
                    <def>Human</def>
                    <id>Pawn1</id>
                    <kindDef>OldPawnKind</kindDef>
                    <genes>
                      <xenotype>OldXenotype</xenotype>
                      <endogenes>
                        <li><def>AptitudePoor_Animals</def><loadID>5</loadID></li>
                        <li><def>ChemicalDependency_GoJuice</def><loadID>6</loadID></li>
                        <li><def>Learning_Fast_Astrogene</def><loadID>8</loadID></li>
                        <li><def>rjw_genes_genetic_disease_immunity_Astrogene</def><loadID>9</loadID></li>
                        <li><def>VREHT_WeaponAptitude_VWE_Gun_SMG</def><loadID>10</loadID></li>
                        <li><def>OldGene</def><loadID>7</loadID></li>
                      </endogenes>
                      <xenogenes />
                      <overriddenByGene>Gene_7</overriddenByGene>
                    </genes>
                  </li>
                </pawns>
                <targets><li>Thing_Animal1</li><selectedPawn>Animal1</selectedPawn></targets>
              </game>
            </savegame>
            """,
            to: saveURL
        )

        let scan = try SaveCleanerService().scan(saveURL: saveURL, modDirectories: [modsURL], configURL: configURL)
        XCTAssertGreaterThan(scan.activeDefCount, 0)
        XCTAssertGreaterThan(scan.changeCount, 0)
        XCTAssertTrue(scan.previewItems.contains { $0.subject == "OldThing" && $0.action == "remove" })
        XCTAssertTrue(scan.previewItems.contains { $0.subject == "OldAnimalKind" && $0.action == "remove" })

        let report = try SaveCleanerService().clean(saveURL: saveURL, modDirectories: [modsURL], configURL: configURL)
        let cleaned = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(report.outputPath)))
        let original = try String(contentsOf: saveURL)

        XCTAssertTrue(original.contains("OldThing"))
        XCTAssertTrue(cleaned.contains("<thingDef>OldThing</thingDef>"))
        XCTAssertTrue(cleaned.contains("<thingDef>Company_0</thingDef>"))
        XCTAssertTrue(cleaned.contains("<recordsDeflate>abc</recordsDeflate>"))
        XCTAssertFalse(cleaned.contains("<thing><def>OldThing</def><id>Old1</id></thing>"))
        XCTAssertTrue(cleaned.contains("KnownThing"))
        XCTAssertTrue(cleaned.contains("Psytrainer_VPE_FiringFocus"))
        XCTAssertTrue(cleaned.contains("Psytrainer_OldAbility"))
        XCTAssertTrue(cleaned.contains("Techprint_KnownResearch"))
        XCTAssertTrue(cleaned.contains("PatchedGene"))
        XCTAssertTrue(cleaned.contains("PatchedThing"))
        XCTAssertTrue(cleaned.contains("Seed_VEE_Mangrove"))
        XCTAssertTrue(cleaned.contains("Corpse_Alpaca"))
        XCTAssertTrue(cleaned.contains("Meat_Alpaca"))
        XCTAssertTrue(cleaned.contains("Neurotrainer_Animals"))
        XCTAssertTrue(cleaned.contains("AptitudePoor_Animals"))
        XCTAssertTrue(cleaned.contains("ChemicalDependency_GoJuice"))
        XCTAssertTrue(cleaned.contains("Learning_Fast_Astrogene"))
        XCTAssertTrue(cleaned.contains("rjw_genes_genetic_disease_immunity_Astrogene"))
        XCTAssertTrue(cleaned.contains("VREHT_WeaponAptitude_VWE_Gun_SMG"))
        XCTAssertTrue(cleaned.contains("<kindDef>Colonist</kindDef>"))
        XCTAssertFalse(cleaned.contains("OldAnimalKind"))
        XCTAssertFalse(cleaned.contains("Animal1"))
        XCTAssertTrue(cleaned.contains("<selectedPawn>null</selectedPawn>"))
        XCTAssertTrue(cleaned.contains("<xenotype>Baseline</xenotype>"))
        XCTAssertFalse(cleaned.contains("OldGene"))
        XCTAssertTrue(cleaned.contains("<overriddenByGene>null</overriddenByGene>"))
    }

    func testSaveCleanerRepairsFactionRelations() throws {
        let dataURL = root.appendingPathComponent("Data/Core/Defs", isDirectory: true)
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        try write(
            "<Defs><ThingDef><defName>Human</defName></ThingDef></Defs>",
            to: dataURL.appendingPathComponent("CoreDefs.xml")
        )
        try write(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <savegame><meta /><game><factionManager><allFactions>
              <li><name>Zero</name><relations><li><other>null</other></li></relations></li>
              <li><name>Source</name><loadID>34</loadID><relations>
                <li><other>Faction_0</other><kind>Hostile</kind><goodwill>-80</goodwill></li>
                <li><other>Faction_43</other><goodwill>9</goodwill></li>
                <li><other>null</other></li>
              </relations></li>
              <li><name>Player</name><loadID>43</loadID><relations><li><other>null</other></li></relations></li>
            </allFactions></factionManager></game></savegame>
            """,
            to: saveURL
        )

        let service = SaveCleanerService()
        let scan = try service.scan(saveURL: saveURL, modDirectories: [root.appendingPathComponent("Data")], configURL: nil)
        XCTAssertEqual(scan.previewItems.filter {
            $0.entity == "Faction relations" && $0.action == "remove"
        }.reduce(0) { $0 + $1.count }, 3)
        XCTAssertEqual(scan.previewItems.filter {
            $0.entity == "Faction relations" && $0.action == "add"
        }.count, 2)

        let report = try service.clean(saveURL: saveURL, modDirectories: [root.appendingPathComponent("Data")], configURL: nil)
        let outputURL = URL(fileURLWithPath: try XCTUnwrap(report.outputPath))
        let document = try XMLDocument(contentsOf: outputURL)
        let rootElement = try XCTUnwrap(document.rootElement())

        XCTAssertEqual(try rootElement.nodes(forXPath: "//factionManager/allFactions/li/relations/li[other='null']").count, 0)
        XCTAssertEqual(try rootElement.nodes(forXPath: "//factionManager/allFactions/li[not(loadID)]/relations/li[other='Faction_34' and kind='Hostile' and goodwill='-80']").count, 1)
        XCTAssertEqual(try rootElement.nodes(forXPath: "//factionManager/allFactions/li[loadID='43']/relations/li[other='Faction_34' and goodwill='9' and not(kind)]").count, 1)

        let rescan = try service.scan(saveURL: outputURL, modDirectories: [root.appendingPathComponent("Data")], configURL: nil)
        XCTAssertFalse(rescan.previewItems.contains { $0.entity == "Faction relations" })
    }

    @discardableResult
    private func addMod(
        in modsURL: URL,
        folder: String,
        packageId: String,
        name: String,
        rootElement: String = "ModMetaData"
    ) throws -> URL {
        let modURL = modsURL.appendingPathComponent(folder, isDirectory: true)
        let aboutURL = modURL.appendingPathComponent("About", isDirectory: true)
        try FileManager.default.createDirectory(at: aboutURL, withIntermediateDirectories: true)
        try write(
            "<\(rootElement)><name>\(name)</name><packageId>\(packageId)</packageId></\(rootElement)>",
            to: aboutURL.appendingPathComponent("About.xml")
        )
        return modURL
    }

    private func write(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url)
    }

    private func managedAssembly(typeNames: [(namespace: String, name: String)]) -> Data {
        var data = Data(repeating: 0, count: 1_024)
        func write(_ value: Int, at offset: Int, bytes: Int) {
            for index in 0..<bytes {
                data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
            }
        }
        func writeString(_ value: String, at offset: Int) {
            data.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8)
            data[offset + value.utf8.count] = 0
        }

        data[0] = 0x4D
        data[1] = 0x5A
        write(0x80, at: 0x3C, bytes: 4)
        write(0x0000_4550, at: 0x80, bytes: 4)
        write(1, at: 0x86, bytes: 2)
        write(0xE0, at: 0x94, bytes: 2)
        write(0x10B, at: 0x98, bytes: 2)
        write(0x2000, at: 0x168, bytes: 4)
        write(0x48, at: 0x16C, bytes: 4)
        write(0x400, at: 0x180, bytes: 4)
        write(0x2000, at: 0x184, bytes: 4)
        write(0x400, at: 0x188, bytes: 4)
        write(0x200, at: 0x18C, bytes: 4)
        write(0x2040, at: 0x208, bytes: 4)

        let metadataRoot = 0x240
        write(0x424A_5342, at: metadataRoot, bytes: 4)
        write(4, at: metadataRoot + 12, bytes: 4)
        writeString("v4", at: metadataRoot + 16)
        write(2, at: metadataRoot + 22, bytes: 2)
        write(0x80, at: metadataRoot + 24, bytes: 4)
        write(0x80, at: metadataRoot + 28, bytes: 4)
        writeString("#~", at: metadataRoot + 32)
        write(0x100, at: metadataRoot + 36, bytes: 4)
        write(0x80, at: metadataRoot + 40, bytes: 4)
        writeString("#Strings", at: metadataRoot + 44)

        let tables = metadataRoot + 0x80
        write(4, at: tables + 8, bytes: 8)
        write(typeNames.count, at: tables + 24, bytes: 4)
        let strings = metadataRoot + 0x100
        var stringCursor = 1
        var rows: [(name: Int, namespace: Int)] = []
        for type in typeNames {
            let nameIndex = stringCursor
            writeString(type.name, at: strings + stringCursor)
            stringCursor += type.name.utf8.count + 1
            let namespaceIndex = stringCursor
            writeString(type.namespace, at: strings + stringCursor)
            stringCursor += type.namespace.utf8.count + 1
            rows.append((nameIndex, namespaceIndex))
        }
        var rowCursor = tables + 28
        for row in rows {
            write(row.name, at: rowCursor + 4, bytes: 2)
            write(row.namespace, at: rowCursor + 6, bytes: 2)
            rowCursor += 14
        }
        return data
    }
}
