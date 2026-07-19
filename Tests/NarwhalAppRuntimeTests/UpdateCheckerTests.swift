import Foundation
import Testing
@testable import NarwhalAppRuntime

@Suite("Update checker decoding")
struct UpdateCheckerTests {
    @Test("Stable GitHub release metadata decodes")
    func stableRelease() throws {
        let release = try decodeUpdateRelease(Data(#"""
        {
          "tag_name": "v1.2.3",
          "html_url": "https://github.com/bbcho/narwhal-dev/releases/tag/v1.2.3",
          "draft": false,
          "prerelease": false
        }
        """#.utf8))

        #expect(release.version.description == "1.2.3")
        #expect(release.pageURL.host == "github.com")
    }

    @Test("Drafts, prereleases, malformed tags, and foreign pages are rejected")
    func rejectedMetadata() {
        let payloads = [
            #"{"tag_name":"v1.2.3","html_url":"https://github.com/bbcho/narwhal-dev/releases","draft":true,"prerelease":false}"#,
            #"{"tag_name":"v1.2.3","html_url":"https://github.com/bbcho/narwhal-dev/releases","draft":false,"prerelease":true}"#,
            #"{"tag_name":"latest","html_url":"https://github.com/bbcho/narwhal-dev/releases","draft":false,"prerelease":false}"#,
            #"{"tag_name":"v1.2.3","html_url":"https://example.com/release","draft":false,"prerelease":false}"#
        ]

        for payload in payloads {
            #expect(throws: UpdateCheckError.self) {
                try decodeUpdateRelease(Data(payload.utf8))
            }
        }
    }
}
