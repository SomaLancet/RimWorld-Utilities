import SwiftUI

struct SettingsSwiftUIView: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        Form {
            Section {
                PageHeaderCard(
                    title: model.title(for: .settings),
                    description: model.localized("Укажите источники данных приложения. Изменения сохраняются автоматически.", "Configure the app data sources. Changes are saved automatically."),
                    symbolName: UtilityPage.settings.symbolName
                )
                .padding(.vertical, 4)
            }

            Section {
                ForEach(SettingsPathKind.allCases) { kind in
                    PathSettingRow(model: model, kind: kind)
                }
            } header: {
                Text(model.localized("Пути к файлам и папкам", "Files and folders"))
            }

            Section {
                LabeledContent {
                    Picker("", selection: Binding(get: { model.settingsState.preferredLanguage }, set: model.changeLanguage)) {
                        ForEach(AppLanguage.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .labelsHidden()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.localized("Язык", "Language"))
                        Text(model.localized("Изменение языка применяется после перезапуска приложения.", "The language change is applied after restarting the app."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(model.localized("Язык интерфейса", "Interface language"))
            }

            Section {
                LabeledContent(model.localized("Версия приложения", "App version")) {
                    Button(model.applicationVersion) {
                        model.openApplicationRepository()
                    }
                    .buttonStyle(.link)
                }
                LabeledContent(model.localized("Обновления", "Updates")) {
                    Button(model.localized("Проверить обновления", "Check for updates")) {
                        model.checkForUpdates()
                    }
                    .disabled(model.isCheckingUpdates)
                }
                if !model.updateStatus.isEmpty {
                    Text(model.updateStatus)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(model.localized("Обновления", "Updates"))
            }

        }
        .formStyle(.grouped)
        .accessibilityIdentifier("page-settings")
    }
}

struct PathSettingRow: View {
    @ObservedObject var model: ApplicationModel
    let kind: SettingsPathKind

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(model.pathLabels[kind] ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ControlGroup {
                    if model.detectedPathAvailable.contains(kind) {
                        Button {
                            model.useDetectedPath(kind)
                        } label: {
                            Text(model.localized("Использовать", "Use"))
                        }
                        .help(model.localized("Использовать найденный путь", "Use detected path"))
                        .accessibilityLabel(model.localized("Использовать", "Use"))
                    }
                    Button {
                        model.openConfiguredPath(kind)
                    } label: {
                        Text(model.localized("Открыть", "Open"))
                    }
                    .disabled(model.settingsState.configuredPath(for: kind) == nil)
                    .help(model.localized("Открыть путь", "Open path"))
                    .accessibilityLabel(model.localized("Открыть", "Open"))
                    Button {
                        model.choosePath(kind)
                    } label: {
                        Text(model.localized("Выбрать…", "Choose…"))
                    }
                    .help(model.localized("Выбрать путь", "Choose path"))
                    .accessibilityLabel(model.localized("Выбрать...", "Choose..."))
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: kind.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(kind.title(using: model))
            }
            .frame(minWidth: 160, alignment: .leading)
        }
    }
}
