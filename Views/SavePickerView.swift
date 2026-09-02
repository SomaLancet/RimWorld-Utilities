import Foundation
import SwiftUI

struct SavePickerView: View {
    @ObservedObject var model: ApplicationModel

    var selectedSave: SaveCandidate? {
        guard let saveURL = model.settingsState.saveURL else { return nil }
        return model.saveCandidates.first { $0.url == saveURL }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Menu {
                    if model.saveCandidates.isEmpty {
                        Text(model.localized("В выбранной папке нет .rws файлов", "No .rws files in the selected folder"))
                    } else {
                        ForEach(model.saveCandidates) { candidate in
                            Button {
                                model.selectSave(candidate.url)
                            } label: {
                                HStack {
                                    Text(candidate.displayName)
                                    Spacer()
                                    Text(formatDate(candidate.modifiedAt))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(selectedSave?.displayName ?? model.localized("Сейв не выбран", "No save selected"))
                            .lineLimit(1)
                        Spacer()
                        if let selectedSave {
                            Text(formatDate(selectedSave.modifiedAt))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(model.saveCandidates.isEmpty)
                Button {
                    model.refreshSaveCandidates()
                } label: {
                    Text(model.localized("Обновить", "Refresh"))
                }
                .help(model.localized("Обновить список сейвов", "Refresh save list"))
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = model.resolvedLanguage == .english ? Locale(identifier: "en_US_POSIX") : Locale(identifier: "ru_RU")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
