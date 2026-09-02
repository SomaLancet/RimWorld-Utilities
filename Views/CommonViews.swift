import AppKit
import SwiftUI

struct PageContainer<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(description)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PageHeaderCard: View {
    let title: String
    let description: String
    let symbolName: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(description)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PlaceholderPage: View {
    let title: String
    let description: String
    let message: String

    var body: some View {
        PageContainer(title: title, description: description) {
            Text(message)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SectionHeader: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .fontWeight(.semibold)
    }
}

struct UtilityTableCount: Identifiable {
    let title: String
    let value: String

    var id: String { title }
}

struct UtilityTableExpansionActions {
    let expandAll: () -> Void
    let collapseAll: () -> Void
    let expandLabel: String
    let collapseLabel: String
}

struct UtilityTablePanel<LeadingActions: View, TrailingActions: View, Content: View>: View {
    let searchPrompt: String?
    var searchText: Binding<String>?
    let counts: [UtilityTableCount]
    let expansionActions: UtilityTableExpansionActions?
    let leadingActions: LeadingActions
    let trailingActions: TrailingActions
    let content: Content

    init(
        searchPrompt: String? = nil,
        searchText: Binding<String>? = nil,
        counts: [UtilityTableCount] = [],
        expansionActions: UtilityTableExpansionActions? = nil,
        @ViewBuilder leadingActions: () -> LeadingActions,
        @ViewBuilder trailingActions: () -> TrailingActions,
        @ViewBuilder content: () -> Content
    ) {
        self.searchPrompt = searchPrompt
        self.searchText = searchText
        self.counts = counts
        self.expansionActions = expansionActions
        self.leadingActions = leadingActions()
        self.trailingActions = trailingActions()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let searchText {
                TextField(searchPrompt ?? "", text: searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: 8) {
                leadingActions
                Spacer(minLength: 8)
                if let expansionActions {
                    ControlGroup {
                        Button(action: expansionActions.expandAll) {
                            Image(systemName: "plus")
                        }
                        .help(expansionActions.expandLabel)
                        .accessibilityLabel(expansionActions.expandLabel)

                        Button(action: expansionActions.collapseAll) {
                            Image(systemName: "minus")
                        }
                        .help(expansionActions.collapseLabel)
                        .accessibilityLabel(expansionActions.collapseLabel)
                    }
                }
                trailingActions
            }
            .frame(maxWidth: .infinity)

            if !counts.isEmpty {
                HStack(spacing: 14) {
                    ForEach(counts) { count in
                        Text(count.title + ": " + count.value)
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct GroupedListHeader: View {
    let title: String
    let detail: String?
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .fontWeight(.semibold)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

struct TableLoadingView: View {
    let title: String
    let detail: String?

    init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct OperationStatusView: View {
    let status: String
    let kind: OperationStatusKind
    let running: Bool
    let progress: Double
    let recentOutput: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if running {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: kind.symbol)
                        .foregroundStyle(kind.color)
                }
                Text(status)
                    .foregroundStyle(kind.color)
            }
            if running && progress > 0 {
                ProgressView(value: progress, total: 100)
            }
            if !recentOutput.isEmpty {
                Text(recentOutput)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ConsoleView: View {
    let text: String
    var minHeight: CGFloat = 120
    var maxHeight: CGFloat?

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

extension DiagnosticProblemRow: Identifiable {
    var id: String { [category ?? "", title, subtitle, details].joined(separator: "|") }

    var categorySymbolName: String {
        switch category {
        case "Проблемы модов", "Mod problems":
            return "puzzlepiece.extension"
        case "Структура сейва", "Save structure":
            return "doc.text.magnifyingglass"
        case "Уведомления", "Notifications":
            return "exclamationmark.bubble"
        case "Следы модов", "Mod traces":
            return "magnifyingglass"
        case "Ошибки Player.log", "Player.log errors":
            return "exclamationmark.triangle"
        default:
            return "exclamationmark.circle"
        }
    }
}
