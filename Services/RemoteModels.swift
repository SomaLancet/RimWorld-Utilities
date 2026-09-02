import Foundation

struct RJWProvider: Decodable, Sendable {
    let type: String
    let name: String
    let displayName: String?
    let description: String
    let infoURL: String?
    let url: String
    let branch: String?
    let subdir: String?
    let disabled: Bool?
    let rimworldVersions: [String]?

    enum CodingKeys: String, CodingKey {
        case type, name, description, url, branch, subdir, disabled
        case displayName = "display_name"
        case infoURL = "info_url"
        case rimworldVersions = "rimworld_versions"
    }
}

struct RJWProvidersResponse: Decodable {
    let providers: [String: [String: RJWProvider]]
}

struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
