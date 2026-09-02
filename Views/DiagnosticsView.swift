import AppKit
import Foundation
import SwiftUI

struct DiagnosticsSwiftUIView: View {
    @ObservedObject var model: ApplicationModel
    @State private var expandedDiagnosticCategories: Set<String> = []

    var body: some View {
        PageContainer(title: model.title(for: .diagnostics), description: model.localized("Проверьте сейв и подготовьте безопасную очищенную копию, если найдены исправимые проблемы.", "Inspect the save and prepare a safe cleaned copy when fixable problems are found.")) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(model.localized("Сейв", "Save"))
                SavePickerView(model: model)
                    .disabled(scannerRunning)

                diagnosticsContent
            }
        }
        .accessibilityIdentifier("page-diagnostics")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(model.localized("Копировать отчет", "Copy report")) {
                    copyScannerReport()
                }
                .disabled(!scannerHasCompleted)
                .help(model.localized("Скопировать результаты сканирования", "Copy scan results"))
            }
        }
        .onAppear {
            model.refreshSaveCandidates()
            expandCurrentDiagnosticCategories()
        }
        .onChange(of: model.diagnosticCategories.map(\.title)) {
            expandCurrentDiagnosticCategories()
        }
    }

    @ViewBuilder
    private var diagnosticsContent: some View {
        switch diagnosticsViewState {
        case .idle:
            diagnosticsEmptyState(
                message: model.localized(
                    "Запустите проверку выбранного сейва.",
                    "Run a check of the selected save."
                ),
                buttonTitle: model.localized("Запустить сканер", "Run scanner")
            )
        case .loading:
            TableLoadingView(
                title: loadingTitle,
                detail: loadingDetail
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            diagnosticsCompletedEmptyState
        case .content:
            diagnosticsResults
        case .error:
            diagnosticsErrorState
        }
    }

    private var diagnosticsResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasDiagnosticProblems && hasSaveCleanerProblems {
                VSplitView {
                    diagnosticProblemsSection
                        .frame(minHeight: 220)
                    safeCleanupSection
                        .frame(minHeight: 220)
                }
            } else if hasDiagnosticProblems {
                diagnosticProblemsSection
            } else if hasSaveCleanerProblems {
                safeCleanupSection
            }

            if shouldShowNoSafeCleanupStatus {
                Label(
                    model.localized(
                        "Безопасная очистка — подходящих изменений не найдено.",
                        "Safe cleanup — no safe changes were found."
                    ),
                    systemImage: "checkmark.circle"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            if model.diagnosticsStatusKind == .error {
                OperationStatusView(
                    status: model.diagnosticsStatus,
                    kind: model.diagnosticsStatusKind,
                    running: false,
                    progress: 0,
                    recentOutput: ""
                )
            }

            if model.saveCleanerStatusKind == .error {
                OperationStatusView(
                    status: model.saveCleanerStatus,
                    kind: model.saveCleanerStatusKind,
                    running: false,
                    progress: 0,
                    recentOutput: ""
                )
            }

            HStack {
                Spacer()
                diagnosticsButton(title: model.localized("Сканировать снова", "Scan again"))
                createCleanedCopyButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var diagnosticProblemsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(model.localized("Диагностика", "Diagnostics"))
            Table(of: DiagnosticProblemRow.self, selection: Binding(get: { model.selectedDiagnostic?.id }, set: { id in
                model.selectedDiagnostic = model.diagnosticCategories.flatMap(\.problems).first { $0.id == id }
            })) {
                TableColumn(model.localized("Проблема", "Issue")) { row in
                    if row.isCategory {
                        HStack(spacing: 6) {
                            Image(systemName: row.categorySymbolName)
                                .foregroundStyle(.secondary)
                            Text(row.title)
                                .fontWeight(.semibold)
                            if !row.subtitle.isEmpty {
                                Text(row.subtitle)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .lineLimit(1)
                            if !row.subtitle.isEmpty {
                                Text(row.subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            } rows: {
                ForEach(model.diagnosticCategories) { group in
                    if !group.problems.isEmpty {
                        DisclosureTableRow(diagnosticCategoryRow(for: group), isExpanded: diagnosticCategoryExpansionBinding(for: group)) {
                            ForEach(group.problems) { problem in
                                TableRow(problem)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 160)

            if model.selectedDiagnostic != nil {
                ConsoleView(text: diagnosticConsoleText, minHeight: 156, maxHeight: 156)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var safeCleanupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(model.localized("Безопасная очистка", "Safe cleanup"))
            SaveCleanerPlanPanel(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var diagnosticsErrorState: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.diagnosticsStatusKind == .error {
                OperationStatusView(
                    status: model.diagnosticsStatus,
                    kind: model.diagnosticsStatusKind,
                    running: false,
                    progress: 0,
                    recentOutput: ""
                )
            }
            if model.saveCleanerStatusKind == .error {
                OperationStatusView(
                    status: model.saveCleanerStatus,
                    kind: model.saveCleanerStatusKind,
                    running: false,
                    progress: 0,
                    recentOutput: ""
                )
            }
            HStack {
                Spacer()
                diagnosticsButton(title: model.localized("Повторить", "Retry"))
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func diagnosticsEmptyState(message: String, buttonTitle: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .foregroundStyle(.secondary)
            diagnosticsButton(title: buttonTitle)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var diagnosticsCompletedEmptyState: some View {
        VStack(spacing: 8) {
            Text(model.localized("Проблем не найдено.", "No problems were found."))
                .foregroundStyle(.secondary)
            HStack {
                diagnosticsButton(title: model.localized("Сканировать снова", "Scan again"))
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                createCleanedCopyButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var createCleanedCopyButton: some View {
        Button(model.localized("Создать очищенную копию", "Create cleaned copy")) {
            model.cleanSaveCleaner()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!hasSaveCleanerProblems || scannerRunning || model.settingsState.saveURL == nil)
    }

    private func diagnosticsButton(title: String) -> some View {
        Button(title) {
            model.runScanner()
        }
        .disabled(model.settingsState.saveURL == nil || scannerRunning)
    }

    private var diagnosticsViewState: DiagnosticsViewState {
        if scannerRunning {
            return .loading
        }
        if model.diagnosticsStatusKind == .error && !hasSaveCleanerProblems {
            return .error
        }
        if model.saveCleanerStatusKind == .error && !hasDiagnosticProblems {
            return .error
        }
        if hasDiagnosticProblems
            || hasSaveCleanerProblems
            || model.diagnosticsStatusKind == .error
            || model.saveCleanerStatusKind == .error {
            return .content
        }
        if scannerHasCompleted {
            return .empty
        }
        return .idle
    }

    private var scannerRunning: Bool {
        model.diagnosticsRunning || model.saveCleanerRunning
    }

    private var hasDiagnosticProblems: Bool {
        !model.diagnosticCategories.allSatisfy(\.problems.isEmpty)
    }

    private var hasSaveCleanerProblems: Bool {
        model.saveCleanerReport?.previewItems.isEmpty == false
    }

    private var shouldShowNoSafeCleanupStatus: Bool {
        hasDiagnosticProblems
            && model.saveCleanerReport?.previewItems.isEmpty == true
            && model.saveCleanerStatusKind == .success
    }

    private var diagnosticsHasCompleted: Bool {
        model.diagnosticsStatusKind == .success || model.diagnosticsStatusKind == .warning
    }

    private var scannerHasCompleted: Bool {
        diagnosticsHasCompleted && model.saveCleanerReport != nil
    }

    private var loadingTitle: String {
        if model.saveCleanerRunning, model.saveCleanerReport != nil, !model.diagnosticsRunning {
            return model.localized("Создаём очищенную копию…", "Creating cleaned copy…")
        }
        return model.localized("Проверяем сохранение…", "Checking save…")
    }

    private var loadingDetail: String {
        if model.saveCleanerRunning, model.saveCleanerReport != nil, !model.diagnosticsRunning {
            return model.localized(
                "Оригинальный сейв останется без изменений.",
                "The original save will remain unchanged."
            )
        }
        return model.localized(
            "Анализируем моды, конфигурацию, журнал ошибок и безопасные варианты очистки.",
            "Analyzing mods, configuration, the error log, and safe cleanup options."
        )
    }

    private var diagnosticConsoleText: String {
        guard let selectedDiagnostic = model.selectedDiagnostic else {
            return model.localized("Выберите проблему слева, чтобы посмотреть подробности.", "Choose an issue on the left to view details.")
        }

        return [
            selectedDiagnostic.title,
            selectedDiagnostic.subtitle,
            "",
            selectedDiagnostic.details
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private func diagnosticCategoryExpansionBinding(for group: DiagnosticProblemGroup) -> Binding<Bool> {
        Binding(
            get: { expandedDiagnosticCategories.contains(group.title) },
            set: { isExpanded in
                if isExpanded {
                    expandedDiagnosticCategories.insert(group.title)
                } else {
                    expandedDiagnosticCategories.remove(group.title)
                }
            }
        )
    }

    private func diagnosticCategoryRow(for group: DiagnosticProblemGroup) -> DiagnosticProblemRow {
        DiagnosticProblemRow(category: group.title, title: group.title, subtitle: "\(group.problems.count)", details: "")
    }

    private func expandCurrentDiagnosticCategories() {
        expandedDiagnosticCategories = Set(model.diagnosticCategories.filter { !$0.problems.isEmpty }.map(\.title))
    }

    private func copyScannerReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(scannerReportText, forType: .string)
    }

    private var scannerReportText: String {
        var lines = [
            "Scanner Report",
            "savePath: \(model.settingsState.saveURL?.path ?? "")",
            "",
            "Diagnostics:",
            model.diagnosticsSummary
        ]

        for group in model.diagnosticCategories where !group.problems.isEmpty {
            lines.append("\(group.title):")
            for problem in group.problems {
                lines.append("- \(problem.title)")
                if !problem.subtitle.isEmpty { lines.append("  \(problem.subtitle)") }
                if !problem.details.isEmpty { lines.append("  \(problem.details)") }
            }
        }

        lines.append("")
        lines.append("Safe cleanup:")
        if let report = model.saveCleanerReport {
            lines.append("activeDefCount: \(report.activeDefCount)")
            lines.append("scannedModCount: \(report.scannedModCount)")
            lines.append("unknownDefCount: \(report.unknownDefCount)")
            lines.append("changeCount: \(report.changeCount)")
            lines.append("outputPath: \(report.outputPath ?? "")")
            for item in report.previewItems {
                lines.append("- \(item.entity): \(item.subject) — \(item.action) \(item.replacement ?? "") (\(item.count))")
            }
        } else {
            lines.append(model.saveCleanerStatus)
        }

        return lines.joined(separator: "\n")
    }
}

private enum DiagnosticsViewState {
    case idle
    case loading
    case empty
    case content
    case error
}

private struct SaveCleanerPlanPanel: View {
    @ObservedObject var model: ApplicationModel
    @State private var expandedGroups: Set<String> = []
    @State private var searchText = ""

    var body: some View {
        UtilityTablePanel(
            searchPrompt: model.localized("Поиск безопасных изменений", "Search safe changes"),
            searchText: $searchText,
            counts: counts,
            expansionActions: UtilityTableExpansionActions(
                expandAll: {
                    expandedGroups = Set(problemGroups.map(\.id))
                },
                collapseAll: {
                    expandedGroups.removeAll()
                },
                expandLabel: model.localized("Раскрыть все категории", "Expand all categories"),
                collapseLabel: model.localized("Свернуть все категории", "Collapse all categories")
            )
        ) {
            EmptyView()
        } trailingActions: {
            EmptyView()
        } content: {
            problemsTable
        }
        .onAppear {
            syncExpandedGroups()
        }
        .onChange(of: problemGroups.map(\.id)) {
            syncExpandedGroups()
        }
    }

    private var problemsTable: some View {
        Table(of: SaveCleanerProblemTableRow.self) {
            TableColumn(model.localized("Объект", "Subject")) { row in
                if row.isGroup {
                    GroupedListHeader(
                        title: row.subject,
                        detail: "\(row.categoryCount)",
                        systemImage: groupIcon(for: row.entity)
                    )
                } else {
                    Text(row.subject)
                        .lineLimit(1)
                }
            }
            .width(min: 140, ideal: 300, max: 720)

            TableColumn(model.localized("Действие", "Action")) { row in
                if row.isGroup {
                    Text("")
                } else {
                    Text(row.actionText)
                        .lineLimit(1)
                }
            }
            .width(min: 72, ideal: 92, max: 140)
        } rows: {
            ForEach(problemGroups) { group in
                DisclosureTableRow(group.headerRow, isExpanded: Binding(
                    get: { expandedGroups.contains(group.id) },
                    set: { isExpanded in
                        if isExpanded {
                            expandedGroups.insert(group.id)
                        } else {
                            expandedGroups.remove(group.id)
                        }
                    }
                )) {
                    ForEach(group.rows) { row in
                        TableRow(row)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var counts: [UtilityTableCount] {
        guard let report = model.saveCleanerReport else { return [] }
        return [
            UtilityTableCount(title: model.localized("Активные Def'ы", "Active Defs"), value: "\(report.activeDefCount)"),
            UtilityTableCount(title: model.localized("Источники", "Sources"), value: "\(report.scannedModCount)"),
            UtilityTableCount(title: model.localized("Неизвестные", "Unknown"), value: "\(report.unknownDefCount)"),
            UtilityTableCount(title: model.localized("Изменения", "Changes"), value: "\(report.changeCount)")
        ]
    }

    private var problemGroups: [SaveCleanerProblemTableGroup] {
        previewGroups.map { group in
            let rows = group.items.map { item in
                SaveCleanerProblemTableRow(
                    entity: item.entity,
                    subject: item.subject,
                    actionText: actionText(for: item),
                    categoryCount: 0
                )
            }
            return SaveCleanerProblemTableGroup(id: group.id, title: group.title, rows: rows)
        }
    }

    private var previewGroups: [SaveCleanerPlanGroup] {
        let items = model.saveCleanerReport?.previewItems ?? []
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let order = [
            "Things and records",
            "Pawn kinds",
            "Xenotypes",
            "Genes",
            "Gene override references",
            "Stuff",
            "Scalar references"
        ]

        return order.compactMap { entity in
            let title = groupTitle(for: entity)
            let groupMatches = normalizedSearch.isEmpty
                || title.lowercased().contains(normalizedSearch)
                || entity.lowercased().contains(normalizedSearch)
            let groupItems = items.filter { item in
                guard item.entity == entity else { return false }
                guard !normalizedSearch.isEmpty else { return true }
                return groupMatches
                    || item.subject.lowercased().contains(normalizedSearch)
                    || actionText(for: item).lowercased().contains(normalizedSearch)
            }
            guard !groupItems.isEmpty else { return nil }
            return SaveCleanerPlanGroup(id: entity, title: title, items: groupItems)
        }
    }

    private func actionText(for item: SaveCleanerPreviewItem) -> String {
        if item.action == "replace", let replacement = item.replacement {
            return model.localized("Заменить на \(replacement)", "Replace with \(replacement)")
        }
        return model.localized("Удалить", "Remove")
    }

    private func groupTitle(for entity: String) -> String {
        switch entity {
        case "Things and records": return model.localized("Вещи и записи", "Things and records")
        case "Pawn kinds": return model.localized("Типы пешек", "Pawn kinds")
        case "Xenotypes": return model.localized("Ксенотипы", "Xenotypes")
        case "Genes": return model.localized("Гены", "Genes")
        case "Gene override references": return model.localized("Ссылки override генов", "Gene override references")
        case "Stuff": return model.localized("Материалы", "Stuff")
        case "Scalar references": return model.localized("Одиночные ссылки", "Scalar references")
        default: return entity
        }
    }

    private func groupIcon(for entity: String) -> String {
        switch entity {
        case "Things and records": return "shippingbox"
        case "Pawn kinds": return "person.crop.circle"
        case "Xenotypes": return "person.2"
        case "Genes": return "sparkles"
        case "Gene override references": return "link"
        case "Stuff": return "square.stack.3d.up"
        case "Scalar references": return "tag"
        default: return "exclamationmark.triangle"
        }
    }

    private func syncExpandedGroups() {
        let ids = Set(problemGroups.map(\.id))
        if expandedGroups.isEmpty {
            expandedGroups = ids
        } else {
            expandedGroups.formIntersection(ids)
        }
    }
}

private struct SaveCleanerPlanGroup: Identifiable {
    let id: String
    let title: String
    let items: [SaveCleanerPreviewItem]
}

private struct SaveCleanerProblemTableGroup: Identifiable {
    let id: String
    let title: String
    let rows: [SaveCleanerProblemTableRow]

    var headerRow: SaveCleanerProblemTableRow {
        SaveCleanerProblemTableRow(
            entity: id,
            subject: title,
            actionText: "",
            categoryCount: rows.count
        )
    }
}

private struct SaveCleanerProblemTableRow: Identifiable {
    let entity: String
    let subject: String
    let actionText: String
    let categoryCount: Int

    var id: String { categoryCount > 0 ? "category|\(entity)" : "item|\(entity)|\(subject)|\(actionText)" }
    var isGroup: Bool { categoryCount > 0 }
}
