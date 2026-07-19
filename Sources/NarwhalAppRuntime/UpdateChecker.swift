import Foundation
import NarwhalAppSupport

enum UpdateCheckError: Error, CustomStringConvertible {
    case invalidResponse
    case responseTooLarge
    case invalidRelease
    case invalidReleasePage

    var description: String {
        switch self {
        case .invalidResponse:
            return "GitHub returned an invalid update response"
        case .responseTooLarge:
            return "GitHub update response exceeded the size limit"
        case .invalidRelease:
            return "GitHub latest release metadata was invalid"
        case .invalidReleasePage:
            return "GitHub latest release page was invalid"
        }
    }
}

struct UpdateRelease: Equatable, Sendable {
    let version: SemanticVersion
    let pageURL: URL
}

struct UpdateChecker: Sendable {
    private static let endpointString = "https://api.github.com/repos/bbcho/narwhal-dev/releases/latest"
    private static let maximumResponseBytes = 1_048_576

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func latestRelease() async throws -> UpdateRelease {
        guard let endpoint = URL(string: Self.endpointString) else {
            throw UpdateCheckError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Narwhal-Update-Check", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200
        else {
            throw UpdateCheckError.invalidResponse
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw UpdateCheckError.responseTooLarge
        }
        return try decodeUpdateRelease(data)
    }
}

func decodeUpdateRelease(_ data: Data) throws -> UpdateRelease {
    struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
        }
    }

    guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
          !release.draft,
          !release.prerelease,
          let version = try? SemanticVersion(release.tagName)
    else {
        throw UpdateCheckError.invalidRelease
    }
    guard release.htmlURL.scheme == "https",
          release.htmlURL.host == "github.com"
    else {
        throw UpdateCheckError.invalidReleasePage
    }
    return UpdateRelease(version: version, pageURL: release.htmlURL)
}
