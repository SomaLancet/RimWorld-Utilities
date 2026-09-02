import Foundation

struct UserFacingError {
    let title: String
    let message: String
    let details: String?

    init(title: String, message: String, details: String? = nil) {
        self.title = title
        self.message = message
        self.details = details?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    init(title: String, message: String, underlyingError: Error) {
        self.init(title: title, message: message, details: underlyingError.localizedDescription)
    }

    var informativeText: String {
        [message, details].compactMap { $0 }.joined(separator: "\n\n")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
