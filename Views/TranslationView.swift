import SwiftUI

struct TranslationSwiftUIView: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        PageContainer(title: model.title(for: .translation), description: model.localized("Загрузите и установите актуальный русский перевод RimWorld, созданный и поддерживаемый сообществом.", "Download and install the latest Russian RimWorld translation created and maintained by the community.")) {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(model.localized("Установленные компоненты", "Installed components"))
                Text(model.translationComponents)
                    .foregroundStyle(.secondary)
                OperationStatusView(status: model.translationStatus, kind: model.translationStatusKind, running: model.translationRunning, progress: model.translationProgress, recentOutput: model.translationRecentOutput)
                ConsoleView(text: model.translationConsole.isEmpty ? model.localized("Вывод системных команд появится после запуска обновления.", "Command output will appear after the update starts.") : model.translationConsole)
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        model.updateTranslation()
                    } label: {
                        Text(model.translationRunning ? model.localized("Отменить", "Cancel") : model.localized("Обновить перевод", "Update translation"))
                    }
                    .disabled(!model.translationRunning && model.rimWorldApplication() == nil)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .accessibilityIdentifier("page-translation")
    }
}
