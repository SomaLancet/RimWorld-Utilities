import SwiftUI

struct RJWSwiftUIView: View {
    @ObservedObject var model: ApplicationModel
    @State private var expandedCategories: Set<String> = []
    @State private var consoleExpanded = false
    @State private var rimWorldVersionFilter = "all"
    @State private var rjwSearchText = ""

    var displayedProviders: [(category: String, provider: RJWProvider)] {
        let versionFiltered = rimWorldVersionFilter == "all"
            ? model.rjwProviders
            : model.rjwProviders.filter { $0.provider.rimworldVersions?.contains(rimWorldVersionFilter) == true }
        let searchText = rjwSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !searchText.isEmpty else { return versionFiltered }
        return versionFiltered.filter { item in
            item.category.lowercased().contains(searchText)
                || item.provider.name.lowercased().contains(searchText)
                || (item.provider.displayName ?? "").lowercased().contains(searchText)
                || item.provider.description.lowercased().contains(searchText)
        }
    }

    var availableRimWorldVersions: [String] {
        Array(Set(model.rjwProviders.flatMap { $0.provider.rimworldVersions ?? [] }))
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
    }

    var providerGroups: [RJWProviderGroup] {
        Dictionary(grouping: displayedProviders, by: \.category).map { category, providers in
            let rows = providers
                .map { RJWProviderRow(category: category, provider: $0.provider) }
                .sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
            return RJWProviderGroup(category: category, rows: rows)
        }
        .sorted { $0.category.localizedStandardCompare($1.category) == .orderedAscending }
    }

    var displayedProviderNames: Set<String> {
        Set(displayedProviders.map(\.provider.name))
    }

    var displayedAvailableProviderNames: Set<String> {
        Set(displayedProviders.compactMap { $0.provider.disabled == true ? nil : $0.provider.name })
    }

    var displayedInstalledProviderNames: Set<String> {
        model.installedRJWProviderNames.intersection(displayedProviderNames)
    }

    var visibleSelectedCount: Int {
        rimWorldVersionFilter != "all" ? model.selectedRJWProviderNames.intersection(displayedProviderNames).count : model.selectedRJWProviderNames.count
    }

    var body: some View {
        let groups = providerGroups

        PageContainer(title: model.title(for: .rjw), description: model.localized("Устанавливайте и удаляйте моды из каталога Libidinous Loader Providers.", "Install and remove mods from the Libidinous Loader Providers catalog.")) {
            VStack(alignment: .leading, spacing: 12) {
                UtilityTablePanel(
                    searchPrompt: model.localized("Поиск модов", "Search mods"),
                    searchText: $rjwSearchText,
                    counts: model.rjwLoadingCatalog ? [] : rjwCounts,
                    expansionActions: UtilityTableExpansionActions(
                        expandAll: {
                            expandedCategories = Set(groups.map(\.id))
                        },
                        collapseAll: {
                            expandedCategories.removeAll()
                        },
                        expandLabel: model.localized("Раскрыть все категории", "Expand all categories"),
                        collapseLabel: model.localized("Свернуть все категории", "Collapse all categories")
                    )
                ) {
                    rjwSelectionActions
                } trailingActions: {
                    rjwCatalogActions()
                } content: {
                    rjwTableContent(groups: groups)
                }
                if model.rjwRunning || !model.rjwStatus.isEmpty {
                    OperationStatusView(status: model.rjwStatus, kind: model.rjwStatusKind, running: model.rjwRunning, progress: model.rjwProgress, recentOutput: "")
                }
                if !model.rjwConsole.isEmpty {
                    DisclosureGroup(
                        model.localized("Вывод команд", "Command output"),
                        isExpanded: $consoleExpanded
                    ) {
                        ConsoleView(text: model.rjwConsole, minHeight: 78, maxHeight: 78)
                    }
                }
                HStack {
                    Spacer()
                    Button {
                        model.applyRJWSelection()
                    } label: {
                        Text(model.rjwRunning ? model.localized("Отменить", "Cancel") : model.localized("Выполнить", "Proceed"))
                    }
                    .disabled(!model.rjwRunning && (model.rjwModsDirectory() == nil || model.rjwProviders.isEmpty))
                }
            }
        }
        .accessibilityIdentifier("page-rjw")
        .onAppear {
            syncExpandedCategories(groups: groups)
        }
        .onChange(of: groups.map(\.id)) {
            syncExpandedCategories(groups: groups)
        }
        .onChange(of: model.rjwRunning) {
            consoleExpanded = model.rjwRunning
        }
    }

    @ViewBuilder
    private func rjwTableContent(groups: [RJWProviderGroup]) -> some View {
        if model.rjwLoadingCatalog {
            TableLoadingView(
                title: model.rjwCatalogMessage,
                detail: model.localized(
                    "Получаем актуальный список доступных модов.",
                    "Fetching the latest list of available mods."
                )
            )
        } else if !model.rjwCatalogMessage.isEmpty && model.rjwProviders.isEmpty {
            Text(model.rjwCatalogMessage)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(of: RJWProviderRow.self) {
                        TableColumn(model.localized("Мод", "Mod")) { row in
                            if let provider = row.provider {
                                Toggle(isOn: Binding(
                                    get: { model.selectedRJWProviderNames.contains(provider.name) },
                                    set: { enabled in
                                        if enabled { model.selectedRJWProviderNames.insert(provider.name) }
                                        else { model.selectedRJWProviderNames.remove(provider.name) }
                                    }
                                )) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(row.displayName)
                                                .lineLimit(1)
                                                .layoutPriority(1)
                                            if let url = provider.pageURL {
                                                Button {
                                                    model.openExternalURL(url)
                                                } label: {
                                                    Text(model.localized("Открыть", "Open"))
                                                }
                                                .buttonStyle(.borderless)
                                                .help(model.localized("Открыть страницу мода", "Open mod page"))
                                            }
                                            if rimWorldVersionFilter == "all", let versionsText = row.versionsText {
                                                Text(versionsText)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Text(provider.description)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2, reservesSpace: true)
                                    }
                                }
                                .disabled(row.isUnavailable)
                                .help(provider.description)
                            } else {
                                GroupedListHeader(
                                    title: row.category,
                                    detail: row.categoryCount.map(String.init),
                                    systemImage: "folder"
                                )
                            }
                        }
                .width(min: 140, ideal: 300, max: 720)
                TableColumn(model.localized("Статус", "Status")) { row in
                    if row.isCategory {
                        Text("")
                    } else {
                        Text(statusText(for: row))
                            .foregroundStyle(statusColor(for: row))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .width(min: 72, ideal: 88, max: 112)
                TableColumn("") { row in
                    if let provider = row.provider,
                       model.installedRJWProviderNames.contains(provider.name) {
                        Button {
                            model.deleteRJWProvider(named: provider.name)
                        } label: {
                            Text(model.localized("Удалить", "Delete"))
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.rjwRunning)
                        .help(model.localized("Удалить установленный мод", "Delete installed mod"))
                        .accessibilityLabel(model.localized("Удалить", "Delete"))
                    } else {
                        Text("")
                    }
                }
                .width(min: 28, ideal: 28, max: 32)
            } rows: {
                ForEach(groups) { group in
                    DisclosureTableRow(group.headerRow, isExpanded: Binding(
                        get: { expandedCategories.contains(group.id) },
                        set: { isExpanded in
                            if isExpanded { expandedCategories.insert(group.id) }
                            else { expandedCategories.remove(group.id) }
                        }
                    )) {
                        ForEach(group.rows) { row in
                            TableRow(row)
                        }
                    }
                }
            }
            .frame(minHeight: 220)
        }
    }

    private func syncExpandedCategories(groups: [RJWProviderGroup]) {
        let ids = Set(groups.map(\.id))
        if expandedCategories.isEmpty {
            expandedCategories = ids
        } else {
            expandedCategories.formIntersection(ids)
        }
    }

    private var rjwCounts: [UtilityTableCount] {
        [
            UtilityTableCount(title: model.localized("Доступно", "Available"), value: "\(displayedProviders.filter { $0.provider.disabled != true }.count)"),
            UtilityTableCount(title: model.localized("Установлено", "Installed"), value: "\(rimWorldVersionFilter != "all" ? displayedInstalledProviderNames.count : model.installedRJWProviderNames.count)"),
            UtilityTableCount(title: model.localized("Выбрано", "Selected"), value: "\(visibleSelectedCount)")
        ]
    }

    private var rjwSelectionActions: some View {
        HStack(spacing: 8) {
            Button(model.localized("Выбрать установленные", "Select installed")) {
                model.detectInstalledRJWProviders()
                if rimWorldVersionFilter != "all" {
                    model.selectedRJWProviderNames.subtract(displayedProviderNames)
                    model.selectedRJWProviderNames.formUnion(displayedInstalledProviderNames)
                } else {
                    model.selectedRJWProviderNames = model.installedRJWProviderNames
                }
            }
            Button(model.localized("Выбрать все", "Select all")) {
                if rimWorldVersionFilter != "all" {
                    model.selectedRJWProviderNames.formUnion(displayedAvailableProviderNames)
                } else {
                    model.selectedRJWProviderNames = displayedAvailableProviderNames
                }
            }
            Button(model.localized("Снять выделение", "Clear selection")) {
                if rimWorldVersionFilter != "all" {
                    model.selectedRJWProviderNames.subtract(displayedProviderNames)
                } else {
                    model.selectedRJWProviderNames.removeAll()
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func rjwCatalogActions() -> some View {
        HStack(spacing: 8) {
            Picker("", selection: $rimWorldVersionFilter) {
                Text(model.localized("Все версии", "All versions")).tag("all")
                ForEach(availableRimWorldVersions, id: \.self) { version in
                    Text(version).tag(version)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 112)
            .help(model.localized("Фильтр по версии RimWorld", "Filter by RimWorld version"))
            Button {
                model.reloadRJWProviders()
            } label: {
                Text(model.localized("Обновить", "Refresh"))
            }
            .help(model.localized("Обновить каталог", "Refresh catalog"))
            .disabled(model.rjwLoadingCatalog)
        }
    }

    private func statusText(for row: RJWProviderRow) -> String {
        if row.isUnavailable {
            return model.localized("Недоступно", "Unavailable")
        }
        guard let provider = row.provider else { return "" }
        if model.installedRJWProviderNames.contains(provider.name) {
            return model.localized("Установлен", "Installed")
        }
        return model.localized("Не установлен", "Not installed")
    }

    private func statusColor(for row: RJWProviderRow) -> Color {
        if row.isUnavailable {
            return .secondary
        }
        guard let provider = row.provider else { return .secondary }
        return model.installedRJWProviderNames.contains(provider.name) ? .green : .secondary
    }
}

struct RJWProviderGroup: Identifiable {
    let category: String
    let rows: [RJWProviderRow]

    var id: String { category }
    var headerRow: RJWProviderRow {
        RJWProviderRow(
            category: category,
            provider: nil,
            categoryCount: rows.filter { !$0.isUnavailable }.count
        )
    }
}

struct RJWProviderRow: Identifiable {
    let category: String
    let provider: RJWProvider?
    let categoryCount: Int?
    let versionsText: String?

    init(category: String, provider: RJWProvider?, categoryCount: Int? = nil) {
        self.category = category
        self.provider = provider
        self.categoryCount = categoryCount
        if let versions = provider?.rimworldVersions, !versions.isEmpty {
            versionsText = versions
                .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
                .joined(separator: ", ")
        } else {
            versionsText = nil
        }
    }

    var id: String { provider.map { category + "|" + $0.name } ?? "category|" + category }
    var displayName: String {
        guard let provider else { return category }
        return provider.displayName ?? provider.name
    }
    var isCategory: Bool { provider == nil }
    var isUnavailable: Bool { provider?.disabled == true }
}

private extension RJWProvider {
    var pageURL: URL? {
        URL(string: infoURL ?? url)
    }
}
