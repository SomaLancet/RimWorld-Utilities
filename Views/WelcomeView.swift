import AppKit
import SwiftUI

struct WelcomeSwiftUIView: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityLabel(model.localized("Значок RimWorld Utilities", "RimWorld Utilities icon"))
            Text("RimWorld Utilities")
                .font(.title2)
                .fontWeight(.semibold)
            Text(model.localized("Переводы, управление модами RJW и диагностика сохранений в одном приложении.", "Translations, RJW mod management, and save diagnostics in one app."))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(model.localized("Обновление перевода  •  Каталог RJW  •  Диагностика сохранений", "Translation updates  •  RJW catalog  •  Save diagnostics"))
                .foregroundStyle(.tertiary)
            HStack {
                Button {
                    model.selectedPage = .translation
                } label: {
                    Text(model.localized("Начать работу", "Getting started"))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.hasConfiguredPaths)
                Button {
                    model.selectedPage = .settings
                } label: {
                    Text(model.localized("Открыть настройки", "Open settings"))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityIdentifier("page-welcome")
    }
}
