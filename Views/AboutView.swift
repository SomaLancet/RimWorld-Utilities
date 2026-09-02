import SwiftUI

struct AboutSwiftUIView: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        PageContainer(title: model.title(for: .about), description: model.localized("Информация о приложении и используемых проектах.", "Application information and related projects.")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.localized("RimWorld Utilities - приложение для обновления community-перевода, управления дополнениями RJW и диагностики сохранений RimWorld.", "RimWorld Utilities updates the community translation, manages RJW add-ons, and diagnoses RimWorld saves."))
                Button(model.applicationVersion) { model.openApplicationRepository() }
                    .buttonStyle(.link)
                SectionHeader(model.localized("Благодарности", "Credits"))
                Text(model.localized("Спасибо авторам Libidinous Loader Providers за предоставленную библиотеку провайдеров и участникам RimWorld-ru за community-перевод игры.", "Thanks to the Libidinous Loader Providers authors for the provider library and to the RimWorld-ru contributors for the community translation."))
                    .foregroundStyle(.secondary)
                Button("Libidinous Loader Providers") { model.openProvidersRepository() }
                    .buttonStyle(.link)
                Button("RimWorld-ru") { model.openTranslationRepository() }
                    .buttonStyle(.link)
            }
        }
        .accessibilityIdentifier("page-about")
    }
}
