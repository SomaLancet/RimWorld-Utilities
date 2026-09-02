import AppKit
import SwiftUI

struct ModRemovalSwiftUIView: View {
    @ObservedObject var model: ApplicationModel
    @FocusState private var modSearchFocused: Bool
    @State private var activeModPackageIds: Set<String> = []
    @State private var activeModPackageIdsLoaded = false
    @State private var saveModPackageIds: Set<String> = []
    @State private var saveModPackageIdsLoading = false
    @State private var modTableSortOrder: [KeyPathComparator<ModRemovalCandidateTableRow>] = [
        .init(\.installedSort, order: .reverse),
        .init(\.displayName)
    ]
    @State private var expandedModRemovalGroups: Set<String> = ["selected", "unselected"]
    @State private var expandedModRemovalPreviewGroups: Set<String> = []
    @State private var knownModRemovalPreviewGroupIDs: Set<String> = []

    var filteredCandidates: [ModRemovalCandidate] {
        let terms = model.modRemovalSearchText
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return model.modRemovalCandidates }
        return model.modRemovalCandidates.filter { candidate in
            terms.allSatisfy { candidate.searchText.contains($0) }
        }
    }

    var searchResults: [ModRemovalCandidate] {
        guard !model.modRemovalSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return Array(filteredCandidates.prefix(8))
    }

    var filteredModRows: [ModRemovalCandidateTableRow] {
        filteredCandidates
            .map { candidate in
                let packageId = candidate.packageId?.lowercased()
                let status: ModRemovalCandidateStatus
                if packageId.map({ activeModPackageIds.contains($0) }) == true {
                    status = .active
                } else if activeModPackageIdsLoaded,
                          packageId.map({ saveModPackageIds.contains($0) }) == true {
                    status = .removed
                } else {
                    status = .inactive
                }
                return ModRemovalCandidateTableRow(
                    category: nil,
                    candidate: candidate,
                    status: status,
                    selected: model.selectedModRemovalModPaths.contains(candidate.id)
                )
            }
            .sorted(using: modTableSortOrder)
    }

    var modTableGroups: [ModRemovalCandidateGroup] {
        let selected = filteredModRows.filter(\.selected)
        let unselected = filteredModRows.filter { !$0.selected }
        return [
            ModRemovalCandidateGroup(id: "selected", title: model.localized("Выбрано", "Selected"), rows: selected),
            ModRemovalCandidateGroup(id: "unselected", title: model.localized("Не выбрано", "Unselected"), rows: unselected)
        ]
    }

    var selectedCandidate: ModRemovalCandidate? {
        model.selectedModRemovalCandidates.first
    }

    var selectedModNames: String {
        let names = model.selectedModRemovalCandidates.map(\.displayName)
        return names.isEmpty ? model.localized("не выбран", "not selected") : names.joined(separator: ", ")
    }

    var modRemovalSelectionCounts: [UtilityTableCount] {
        var counts = [
            UtilityTableCount(title: model.localized("Всего найдено модов", "Total mods found"), value: "\(model.modRemovalCandidates.count)")
        ]
        if !model.modRemovalSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            counts.append(UtilityTableCount(title: model.localized("Показано", "Showing"), value: "\(filteredCandidates.count)"))
        }
        counts.append(UtilityTableCount(title: model.localized("Выбрано", "Selected"), value: "\(model.selectedModRemovalModPaths.count)"))
        return counts
    }

    var body: some View {
        PageContainer(title: model.title(for: .modRemoval), description: model.localized("Найдите следы выбранного мода в сейве и подготовьте осторожную очистку.", "Find traces of a selected mod in the save and prepare a conservative cleanup.")) {
            VStack(alignment: .leading, spacing: 16) {
                ModRemovalStepIndicator(
                    steps: ModRemovalWizardStep.allCases,
                    selectedStep: model.modRemovalSelectedStep,
                    title: stepTitle,
                    status: stepStatus,
                    canSelect: canNavigate(to:)
                ) { step in
                    moveToStep(step)
                }

                Divider()

                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Spacer(minLength: 0)

                HStack {
                    Button {
                        goBack()
                    } label: {
                        Text(model.localized("Назад", "Back"))
                    }
                    .disabled(model.modRemovalSelectedStep == .save)

                    Spacer()

                    switch model.modRemovalSelectedStep {
                    case .scan where model.modRemovalReport == nil:
                        Button {
                            model.scanModRemoval()
                        } label: {
                            Text(model.localized("Сканировать", "Scan"))
                        }
                        .disabled(model.settingsState.saveURL == nil || model.selectedModRemovalModPaths.isEmpty || model.modRemovalRunning)
                        .keyboardShortcut(.defaultAction)
                    case .clean:
                        Button {
                            model.cleanModRemoval()
                        } label: {
                            Text(model.localized("Очистить сейв", "Clean Save"))
                        }
                        .disabled(model.settingsState.saveURL == nil || model.modRemovalModURL == nil || model.modRemovalRunning || model.modRemovalReport == nil)
                        .keyboardShortcut(.defaultAction)
                    default:
                        Button {
                            goNext()
                        } label: {
                            Text(model.localized("Далее", "Next"))
                        }
                        .disabled(!canGoNext)
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .onAppear {
            model.refreshSaveCandidates()
            reloadActiveModPackageIds()
            if model.modRemovalCandidates.isEmpty {
                model.refreshModRemovalCandidates()
            }
            syncExpandedModRemovalPreviewGroups()
        }
        .onChange(of: model.settingsState.configURL) {
            reloadActiveModPackageIds()
        }
        .onChange(of: modRemovalPreviewTableGroups.map(\.id)) {
            syncExpandedModRemovalPreviewGroups()
        }
        .task(id: model.settingsState.saveURL) {
            await reloadSaveModPackageIds()
        }
        .accessibilityIdentifier("page-mod-removal")
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.modRemovalSelectedStep {
        case .save:
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(stepTitle(.save))
                SavePickerView(model: model)
            }
        case .mod:
            modSelectionStep
        case .scan:
            scanStep
        case .clean:
            cleanStep
        }
    }

    private var modSelectionStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(stepTitle(.mod))
            UtilityTablePanel(
                searchPrompt: model.localized("Поиск по названию или packageId", "Search by name or packageId"),
                searchText: $model.modRemovalSearchText,
                counts: modRemovalSelectionCounts
            ) {
                HStack(spacing: 8) {
                    Button {
                        selectVisibleRemovedMods()
                    } label: {
                        Text(model.localized("Выбрать Removed", "Select Removed"))
                    }
                    .disabled(
                        model.modRemovalCatalogLoading
                            || !activeModPackageIdsLoaded
                            || saveModPackageIdsLoading
                            || filteredModRows.allSatisfy { $0.status != .removed || $0.selected }
                    )

                    Button {
                        clearModRemovalSelection()
                    } label: {
                        Text(model.localized("Снять выделение", "Clear selection"))
                    }
                    .disabled(model.selectedModRemovalModPaths.isEmpty)
                }
            } trailingActions: {
                Button {
                    reloadActiveModPackageIds()
                    model.refreshModRemovalCandidates()
                    Task { await reloadSaveModPackageIds() }
                } label: {
                    Text(model.localized("Обновить", "Refresh"))
                }
                .help(model.localized("Обновить список модов", "Refresh mod list"))
                .disabled(modSelectionLoading)
            } content: {
                if modSelectionLoading {
                    TableLoadingView(
                        title: modSelectionLoadingTitle,
                        detail: modSelectionLoadingDetail
                    )
                } else {
                    Table(of: ModRemovalCandidateTableRow.self, sortOrder: $modTableSortOrder) {
                        TableColumn(model.localized("Мод", "Mod"), value: \.displayName) { row in
                            if row.isGroup {
                                GroupedListHeader(
                                    title: row.category ?? "",
                                    detail: "\(row.categoryCount)",
                                    systemImage: "folder"
                                )
                            } else if let candidate = row.candidate {
                                Toggle(isOn: Binding(
                                    get: { model.selectedModRemovalModPaths.contains(candidate.id) },
                                    set: { selected in model.setModRemovalCandidate(candidate, selected: selected) }
                                )) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.displayName)
                                            .lineLimit(1)
                                        if !row.packageId.isEmpty {
                                            Text(row.packageId)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                        .width(min: 140, ideal: 320, max: 720)
                        TableColumn(model.localized("Статус", "Status"), value: \.installedSort) { row in
                            if row.isGroup {
                                Text("")
                            } else {
                                Text(statusText(for: row))
                                    .foregroundStyle(statusColor(for: row.status))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        .width(min: 72, ideal: 88, max: 112)
                    } rows: {
                        ForEach(modTableGroups) { group in
                            DisclosureTableRow(group.headerRow, isExpanded: Binding(
                                get: { expandedModRemovalGroups.contains(group.id) },
                                set: { isExpanded in
                                    if isExpanded { expandedModRemovalGroups.insert(group.id) }
                                    else { expandedModRemovalGroups.remove(group.id) }
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
            }
        }
    }

    private var modSelectionLoading: Bool {
        model.modRemovalCatalogLoading || saveModPackageIdsLoading
    }

    private var modSelectionLoadingTitle: String {
        model.modRemovalCatalogLoading
            ? model.localized("Ищем установленные моды…", "Finding installed mods…")
            : model.localized("Сверяем моды…", "Comparing mods…")
    }

    private var modSelectionLoadingDetail: String {
        model.modRemovalCatalogLoading
            ? model.localized("Проверяем настроенные папки модов.", "Checking the configured mod folders.")
            : model.localized(
                "Сопоставляем моды из сейва с активной конфигурацией.",
                "Matching the save's mods with the active configuration."
            )
    }

    private var scanStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(stepTitle(.scan))
            OperationStatusView(
                status: model.modRemovalStatus,
                kind: model.modRemovalStatusKind,
                running: model.modRemovalRunning,
                progress: 0,
                recentOutput: ""
            )
            if let report = model.modRemovalReport, report.matchedDefCount == 0 {
                Text(model.localized("Переход к очистке недоступен: в сейве не найдено ссылок на Def'ы выбранного мода.", "Cannot continue to cleanup: no references to this mod's Defs were found in the save."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.modRemovalRunning {
                TableLoadingView(
                    title: model.localized("Анализируем сейв…", "Analyzing save…"),
                    detail: model.localized(
                        "Ищем данные, связанные с выбранными модами.",
                        "Finding data associated with the selected mods."
                    )
                )
                .frame(minHeight: 260)
            } else {
                Table(of: ModRemovalPreviewTableRow.self) {
                TableColumn(model.localized("Объект", "Subject")) { row in
                    if row.isGroup {
                        GroupedListHeader(
                            title: row.groupTitle ?? "",
                            detail: row.groupDetail,
                            systemImage: row.groupSystemImage ?? "folder"
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.subject)
                                .lineLimit(1)
                            if let detail = row.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(row.isInformational ? 2 : 1)
                            }
                        }
                    }
                }
                .width(min: 140, ideal: 240, max: 720)
                TableColumn(model.localized("Действие", "Action")) { row in
                    if !row.isGroup {
                        Text(row.action)
                            .lineLimit(1)
                    }
                }
                .width(min: 80, ideal: 96, max: 140)
                TableColumn(model.localized("Количество", "Count")) { row in
                    if let count = row.count {
                        Text("\(count)")
                            .lineLimit(1)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .width(min: 72, ideal: 80, max: 96)
            } rows: {
                ForEach(modRemovalPreviewTableGroups) { group in
                    DisclosureTableRow(
                        group.headerRow,
                        isExpanded: modRemovalPreviewGroupExpansionBinding(for: group)
                    ) {
                        ForEach(group.rows) { row in
                            TableRow(row)
                        }
                    }
                }
            }
            .overlay {
                if model.modRemovalReport == nil {
                    Text(model.localized("После сканирования здесь появится план удаления.", "The removal plan will appear here after scanning."))
                        .foregroundStyle(.secondary)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 260)
            }
        }
    }

    private func cleanupPreviewGroupIcon(for entity: String) -> String {
        switch entity {
        case "Save mod list entries": return "list.bullet.rectangle"
        case "Factions", "Faction relations", "Faction references": return "flag"
        case "Settlements and world objects": return "building.2"
        case "Pawn kinds": return "person.crop.circle"
        case "Xenotypes": return "person.2"
        case "Genes": return "sparkles"
        case "Gene override references": return "link"
        case "Things and items": return "shippingbox"
        case "Stuff": return "square.stack.3d.up"
        case "Scalar references": return "tag"
        case "Dictionary entries": return "book"
        case "Simple list references": return "list.bullet"
        default: return "exclamationmark.triangle"
        }
    }

    private func modRemovalActionText(for item: ModRemovalPreviewItem) -> String {
        if item.action == "replace", let replacement = item.replacement {
            return model.localized("Заменить на \(replacement)", "Replace with \(replacement)")
        }
        return model.localized("Удалить", "Remove")
    }

    private var cleanupPreviewGroups: [ModRemovalPlanGroup] {
        let items = model.modRemovalReport?.previewItems ?? []
        let order = [
            "Save mod list entries",
            "Factions",
            "Settlements and world objects",
            "Faction relations",
            "Faction references",
            "Pawn kinds",
            "Xenotypes",
            "Genes",
            "Gene override references",
            "Things and items",
            "Stuff",
            "Scalar references",
            "Dictionary entries",
            "Simple list references"
        ]
        return order.compactMap { entity in
            let groupItems = items.filter { $0.entity == entity }
            guard !groupItems.isEmpty else { return nil }
            return ModRemovalPlanGroup(id: entity, title: previewGroupTitle(for: entity), items: groupItems)
        }
    }

    private var modRemovalPreviewTableGroups: [ModRemovalPreviewTableGroup] {
        var groups = cleanupPreviewGroups.map { group in
            ModRemovalPreviewTableGroup(
                id: group.id,
                title: group.title,
                detail: "\(group.items.count)",
                systemImage: cleanupPreviewGroupIcon(for: group.id),
                rows: group.items.map { item in
                    ModRemovalPreviewTableRow(
                        id: item.id,
                        groupTitle: nil,
                        groupDetail: nil,
                        groupSystemImage: nil,
                        subject: item.subject,
                        detail: item.sourceModName,
                        action: modRemovalActionText(for: item),
                        count: item.count,
                        isInformational: false
                    )
                }
            )
        }

        if ignoredReferenceCount > 0 {
            groups.append(
                ModRemovalPreviewTableGroup(
                    id: "ignored-references",
                    title: model.localized("Не будет изменено", "Will not be changed"),
                    detail: "\(ignoredReferenceCount)",
                    systemImage: "eye",
                    rows: [
                        ModRemovalPreviewTableRow(
                            id: "ignored-references-row",
                            groupTitle: nil,
                            groupDetail: nil,
                            groupSystemImage: nil,
                            subject: model.localized("Чужие ссылки", "Foreign references"),
                            detail: model.localized(
                                "Это зависимости, найденные внутри выбранных модов, а не данные сейва, которыми эти моды владеют. Они останутся без изменений.",
                                "These are dependencies found inside the selected mods, not save data owned by those mods. They will stay unchanged."
                            ),
                            action: model.localized("Без изменений", "Unchanged"),
                            count: ignoredReferenceCount,
                            isInformational: true
                        )
                    ]
                )
            )
        }

        return groups
    }

    private func modRemovalPreviewGroupExpansionBinding(for group: ModRemovalPreviewTableGroup) -> Binding<Bool> {
        Binding(
            get: { expandedModRemovalPreviewGroups.contains(group.id) },
            set: { isExpanded in
                if isExpanded {
                    expandedModRemovalPreviewGroups.insert(group.id)
                } else {
                    expandedModRemovalPreviewGroups.remove(group.id)
                }
            }
        )
    }

    private func syncExpandedModRemovalPreviewGroups() {
        let ids = Set(modRemovalPreviewTableGroups.map(\.id))
        guard !ids.isEmpty else {
            expandedModRemovalPreviewGroups.removeAll()
            knownModRemovalPreviewGroupIDs.removeAll()
            return
        }
        expandedModRemovalPreviewGroups.formIntersection(ids)
        expandedModRemovalPreviewGroups.formUnion(ids.subtracting(knownModRemovalPreviewGroupIDs))
        knownModRemovalPreviewGroupIDs = ids
    }

    private var ignoredReferenceCount: Int {
        model.modRemovalReport?.foreignReferenceCount ?? 0
    }

    private func previewGroupTitle(for entity: String) -> String {
        switch entity {
        case "Save mod list entries": return model.localized("Записи модов в сейве", "Save mod list entries")
        case "Factions": return model.localized("Фракции", "Factions")
        case "Settlements and world objects": return model.localized("Поселения и объекты мира", "Settlements and world objects")
        case "Faction relations": return model.localized("Отношения фракций", "Faction relations")
        case "Faction references": return model.localized("Ссылки на фракции", "Faction references")
        case "Pawn kinds": return model.localized("Типы пешек", "Pawn kinds")
        case "Xenotypes": return model.localized("Ксенотипы", "Xenotypes")
        case "Genes": return model.localized("Гены", "Genes")
        case "Gene override references": return model.localized("Ссылки override генов", "Gene override references")
        case "Things and items": return model.localized("Вещи и предметы", "Things and items")
        case "Stuff": return model.localized("Материалы", "Stuff")
        case "Scalar references": return model.localized("Одиночные ссылки", "Scalar references")
        case "Dictionary entries": return model.localized("Записи словарей", "Dictionary entries")
        case "Simple list references": return model.localized("Ссылки в списках", "Simple list references")
        default: return entity
        }
    }

    private var cleanStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(stepTitle(.clean))
            cleanSummary
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .layoutPriority(1)
            if model.modRemovalRunning || model.modRemovalStatusKind == .success || model.modRemovalStatusKind == .error {
                OperationStatusView(
                    status: model.modRemovalStatus,
                    kind: model.modRemovalStatusKind,
                    running: model.modRemovalRunning,
                    progress: model.modRemovalProgress,
                    recentOutput: ""
                )
            }
            Text(model.localized("Оригинальный сейв не изменяется. Очищенная копия будет сохранена рядом с ним.", "The original save is not changed. The cleaned copy will be saved next to it."))
                .foregroundStyle(.secondary)
            Picker(model.localized("Режим очистки", "Cleanup mode"), selection: Binding(
                get: { model.modRemovalRemoveMetadata },
                set: { value in
                    model.modRemovalRemoveMetadata = value
                }
            )) {
                Text(model.localized("Сохранить запись о моде", "Keep mod entry")).tag(false)
                Text(model.localized("Удалить запись о моде", "Remove mod entry")).tag(true)
            }
            .pickerStyle(.segmented)
            Text(model.modRemovalRemoveMetadata
                ? model.localized("Мод будет удалён из игровых данных и списка модов сейва.", "The mod will be removed from game data and the save's mod list.")
                : model.localized("Будут очищены игровые данные; modId/modName останутся для штатного предупреждения RimWorld.", "Game data will be cleaned; modId/modName will stay for RimWorld's normal missing-mod warning."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var cleanSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.localized("Проверьте параметры перед очисткой.", "Review the cleanup settings before cleaning."))
                .fontWeight(.semibold)
            Text(model.localized("Сейв", "Save") + ": " + (model.settingsState.saveURL?.path ?? model.localized("не выбран", "not selected")))
                .lineLimit(2)
                .truncationMode(.middle)
            Text(model.localized("Моды", "Mods") + ":")
            ScrollView {
                Text(selectedModNames)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private var canGoNext: Bool {
        isComplete(model.modRemovalSelectedStep)
    }

    private func canNavigate(to step: ModRemovalWizardStep) -> Bool {
        step.rawValue <= model.modRemovalSelectedStep.rawValue || ModRemovalWizardStep.allCases.prefix(step.rawValue).allSatisfy(isComplete)
    }

    private func goBack() {
        guard let previous = ModRemovalWizardStep(rawValue: model.modRemovalSelectedStep.rawValue - 1) else { return }
        moveToStep(previous)
    }

    private func goNext() {
        guard canGoNext, let next = ModRemovalWizardStep(rawValue: model.modRemovalSelectedStep.rawValue + 1) else { return }
        moveToStep(next)
    }

    private func moveToStep(_ step: ModRemovalWizardStep) {
        if step == .mod, model.modRemovalSelectedStep != .mod {
            model.modRemovalModURL = nil
            model.selectedModRemovalModPaths = []
            model.modRemovalSearchText = ""
            model.modRemovalReport = nil
            model.modRemovalStatus = model.localized("Выберите мод и запустите сканирование.", "Choose a mod and run a scan.")
            model.modRemovalStatusKind = .idle
        }
        model.modRemovalSelectedStep = step
    }

    private func isComplete(_ step: ModRemovalWizardStep) -> Bool {
        switch step {
        case .save:
            return model.settingsState.saveURL != nil
        case .mod:
            return !model.selectedModRemovalModPaths.isEmpty
        case .scan:
            return (model.modRemovalReport?.matchedDefCount ?? 0) > 0
        case .clean:
            return model.modRemovalReport?.outputPath != nil
        }
    }

    private func stepStatus(_ step: ModRemovalWizardStep) -> ModRemovalWizardStepStatus {
        if model.modRemovalSelectedStep == step {
            return .current
        }
        return step.rawValue < model.modRemovalSelectedStep.rawValue && isComplete(step) ? .completed : .pending
    }

    private func stepTitle(_ step: ModRemovalWizardStep) -> String {
        switch step {
        case .save:
            return model.localized("Шаг 1. Выберите сейв", "Step 1. Choose a save")
        case .mod:
            return model.localized("Шаг 2. Выберите мод", "Step 2. Choose a mod")
        case .scan:
            return model.localized("Шаг 3. Просканируйте сейв", "Step 3. Scan the save")
        case .clean:
            return model.localized("Шаг 4. Очистите сейв", "Step 4. Clean the save")
        }
    }

    private func selectVisibleRemovedMods() {
        for row in filteredModRows where row.status == .removed {
            guard let candidate = row.candidate else { continue }
            model.setModRemovalCandidate(candidate, selected: true)
        }
    }

    private func clearModRemovalSelection() {
        model.selectedModRemovalModPaths = []
        model.modRemovalModURL = nil
        model.modRemovalReport = nil
        model.modRemovalStatus = model.localized("Выберите мод и запустите сканирование.", "Choose a mod and run a scan.")
        model.modRemovalStatusKind = .idle
    }

    private func reloadActiveModPackageIds() {
        guard let configURL = model.settingsState.configURL,
              let xml = try? XMLValues.read(configURL) else {
            activeModPackageIds = []
            activeModPackageIdsLoaded = false
            return
        }
        activeModPackageIds = Set(xml.list("/ModsConfigData/activeMods/li").map { $0.lowercased() })
        activeModPackageIdsLoaded = true
    }

    @MainActor
    private func reloadSaveModPackageIds() async {
        guard let saveURL = model.settingsState.saveURL else {
            saveModPackageIds = []
            saveModPackageIdsLoading = false
            return
        }

        saveModPackageIdsLoading = true
        let packageIds = await Task.detached(priority: .userInitiated) {
            guard let xml = try? XMLValues.read(saveURL) else { return Set<String>() }
            return Set(xml.list("/savegame/meta/modIds/li").map { $0.lowercased() })
        }.value
        guard model.settingsState.saveURL == saveURL else { return }
        saveModPackageIds = packageIds
        saveModPackageIdsLoading = false
    }

    private func statusText(for row: ModRemovalCandidateTableRow) -> String {
        switch row.status {
        case .active: return model.localized("Активен", "Active")
        case .removed: return "Removed"
        case .inactive: return model.localized("Неактивен", "Inactive")
        }
    }

    private func statusColor(for status: ModRemovalCandidateStatus) -> Color {
        switch status {
        case .active: return .green
        case .removed: return .orange
        case .inactive: return .secondary
        }
    }

    private func selectSearchResult(_ candidate: ModRemovalCandidate) {
        model.selectModRemovalCandidate(candidate)
        model.modRemovalSearchText = candidate.displayName
        modSearchFocused = false
    }
}

enum ModRemovalWizardStep: Int, CaseIterable, Identifiable {
    case save
    case mod
    case scan
    case clean

    var id: Int { rawValue }
}

enum ModRemovalWizardStepStatus {
    case completed
    case current
    case pending
}

struct ModRemovalStepIndicator: View {
    let steps: [ModRemovalWizardStep]
    let selectedStep: ModRemovalWizardStep
    let title: (ModRemovalWizardStep) -> String
    let status: (ModRemovalWizardStep) -> ModRemovalWizardStepStatus
    let canSelect: (ModRemovalWizardStep) -> Bool
    let select: (ModRemovalWizardStep) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(steps) { step in
                Button {
                    select(step)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 0) {
                            stepSymbol(for: step)
                            if step != steps.last {
                                Rectangle()
                                    .fill(lineColor(after: step))
                                    .frame(height: 1)
                                    .frame(maxWidth: .infinity)
                                    .padding(.leading, 8)
                            }
                        }
                        Text(title(step))
                            .font(.caption)
                            .fontWeight(selectedStep == step ? .semibold : .regular)
                            .foregroundStyle(selectedStep == step ? .primary : .secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSelect(step))
            }
        }
    }

    private func stepSymbol(for step: ModRemovalWizardStep) -> some View {
        ZStack {
            Circle()
                .fill(statusFillColor(for: step))
                .frame(width: 22, height: 22)
            switch status(step) {
            case .completed:
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            case .current:
                Circle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: 14, height: 14)
            case .pending:
                Circle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 8, height: 8)
            }
        }
    }

    private func lineColor(after step: ModRemovalWizardStep) -> Color {
        status(step) == .completed ? .accentColor : Color.secondary.opacity(0.25)
    }

    private func statusFillColor(for step: ModRemovalWizardStep) -> Color {
        switch status(step) {
        case .completed: return .accentColor
        case .current: return Color.accentColor.opacity(0.15)
        case .pending: return Color.secondary.opacity(0.18)
        }
    }
}

struct ModRemovalPlanGroup: Identifiable {
    let id: String
    let title: String
    let items: [ModRemovalPreviewItem]
}

private struct ModRemovalPreviewTableGroup: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let rows: [ModRemovalPreviewTableRow]

    var headerRow: ModRemovalPreviewTableRow {
        ModRemovalPreviewTableRow(
            id: "group|\(id)",
            groupTitle: title,
            groupDetail: detail,
            groupSystemImage: systemImage,
            subject: "",
            detail: nil,
            action: "",
            count: nil,
            isInformational: false
        )
    }
}

private struct ModRemovalPreviewTableRow: Identifiable {
    let id: String
    let groupTitle: String?
    let groupDetail: String?
    let groupSystemImage: String?
    let subject: String
    let detail: String?
    let action: String
    let count: Int?
    let isInformational: Bool

    var isGroup: Bool { groupTitle != nil }
}

struct ModRemovalCandidateGroup: Identifiable {
    let id: String
    let title: String
    let rows: [ModRemovalCandidateTableRow]

    var headerRow: ModRemovalCandidateTableRow {
        ModRemovalCandidateTableRow(category: title, candidate: nil, status: .inactive, selected: id == "selected", categoryCount: rows.count)
    }
}

enum ModRemovalCandidateStatus: Int, Comparable {
    case inactive
    case removed
    case active

    static func < (lhs: ModRemovalCandidateStatus, rhs: ModRemovalCandidateStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ModRemovalCandidateTableRow: Identifiable {
    let category: String?
    let candidate: ModRemovalCandidate?
    let status: ModRemovalCandidateStatus
    let selected: Bool
    var categoryCount: Int = 0

    var id: String { candidate?.id ?? "category|\(category ?? "")" }
    var isGroup: Bool { candidate == nil }
    var displayName: String { candidate?.displayName ?? category ?? "" }
    var packageId: String { candidate?.packageId ?? "" }
    var installedSort: Int { status.rawValue }
}
