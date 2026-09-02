import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
enum OperationStatusKind: Equatable {
    case idle
    case ready
    case running
    case success
    case warning
    case error

    var color: Color {
        switch self {
        case .success: return .green
        case .warning: return .secondary
        case .error: return .red
        default: return .primary
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "checkmark.circle"
        case .running: return "progress.indicator"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle"
        case .error: return "exclamationmark.triangle.fill"
        case .idle: return "circle"
        }
    }
}

struct DiagnosticProblemGroup: Identifiable {
    let id = UUID()
    let title: String
    let problems: [DiagnosticProblemRow]
}

extension SettingsPathKind: Identifiable {
    var id: Int { rawValue }
    var symbolName: String {
        switch self {
        case .save: return "doc"
        case .localMods: return "folder"
        case .workshopMods: return "shippingbox"
        case .config: return "doc.text"
        case .log: return "text.document"
        }
    }
}

@MainActor
extension SettingsPathKind {
    func title(using model: ApplicationModel) -> String {
        switch self {
        case .save: return model.localized("Папка сохранений", "Saves folder")
        case .localMods: return model.localized("Локальные моды", "Local mods")
        case .workshopMods: return "Steam Workshop"
        case .config: return "ModsConfig.xml"
        case .log: return "Player.log"
        }
    }
}

struct RootView: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            List(selection: $model.selectedPage) {
                NavigationLink(value: UtilityPage.welcome) {
                    Label(model.title(for: .welcome), systemImage: UtilityPage.welcome.symbolName)
                }
                .accessibilityIdentifier("sidebar-welcome")
                Section(model.localized("УТИЛИТЫ", "UTILITIES")) {
                    NavigationLink(value: UtilityPage.translation) {
                        Label(model.title(for: .translation), systemImage: UtilityPage.translation.symbolName)
                    }
                    .accessibilityIdentifier("sidebar-translation")
                    NavigationLink(value: UtilityPage.rjw) {
                        Label(model.title(for: .rjw), systemImage: UtilityPage.rjw.symbolName)
                    }
                    .accessibilityIdentifier("sidebar-rjw")
                    Label(model.title(for: .modsManager), systemImage: UtilityPage.modsManager.symbolName)
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("sidebar-mods-manager")
                }
                Section(model.localized("ОБСЛУЖИВАНИЕ", "MAINTENANCE")) {
                    NavigationLink(value: UtilityPage.diagnostics) {
                        Label(model.title(for: .diagnostics), systemImage: UtilityPage.diagnostics.symbolName)
                    }
                    .accessibilityIdentifier("sidebar-diagnostics")
                    NavigationLink(value: UtilityPage.modRemoval) {
                        Label(model.title(for: .modRemoval), systemImage: UtilityPage.modRemoval.symbolName)
                    }
                    .accessibilityIdentifier("sidebar-mod-removal")
                }
                Section(model.localized("ПРИЛОЖЕНИЕ", "APPLICATION")) {
                    NavigationLink(value: UtilityPage.settings) {
                        Label(model.title(for: .settings), systemImage: UtilityPage.settings.symbolName)
                    }
                    .accessibilityIdentifier("sidebar-settings")
                    NavigationLink(value: UtilityPage.about) {
                        Label(model.title(for: .about), systemImage: UtilityPage.about.symbolName)
                    }
                    .accessibilityIdentifier("sidebar-about")
                }
                Spacer()
                Button(model.applicationVersion) {
                    model.openApplicationRepository()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .font(.caption)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            Group {
                switch model.selectedPage {
                case .welcome:
                    WelcomeSwiftUIView(model: model)
                case .translation:
                    TranslationSwiftUIView(model: model)
                case .rjw:
                    RJWSwiftUIView(model: model)
                case .modsManager:
                    PlaceholderPage(title: model.title(for: .modsManager), description: model.localized("Управление обычными модами RimWorld.", "Manage regular RimWorld mods."), message: model.localized("Раздел менеджера модов находится в разработке.", "The Mods Manager section is under development."))
                case .diagnostics:
                    DiagnosticsSwiftUIView(model: model)
                case .modRemoval:
                    ModRemovalSwiftUIView(model: model)
                case .settings:
                    SettingsSwiftUIView(model: model)
                case .about:
                    AboutSwiftUIView(model: model)
                }
            }
            .frame(minWidth: 480, minHeight: 520)
        }
        .navigationTitle("RimWorld Utilities")
    }
}
