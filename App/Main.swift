import AppKit
import Foundation

private var retainedAppDelegate: AppDelegate?

private enum AnalyzeJSONCommand {
    static func runIfRequested(arguments: [String]) -> Bool {
        guard arguments.count >= 6, arguments[1] == "--analyze-json" else { return false }

        let save = URL(fileURLWithPath: arguments[2])
        let config = URL(fileURLWithPath: arguments[3])
        let log = URL(fileURLWithPath: arguments[4])
        let modDirectories = arguments.dropFirst(5).map { URL(fileURLWithPath: $0, isDirectory: true) }

        do {
            let report = try RimWorldAnalyzer().analyze(save: save, modDirectories: modDirectories, config: config, log: log)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(report))
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(2)
        }

        return true
    }
}

@main
private enum RimWorldUtilitiesMain {
    static func main() {
        if AnalyzeJSONCommand.runIfRequested(arguments: CommandLine.arguments) {
            return
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        retainedAppDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
