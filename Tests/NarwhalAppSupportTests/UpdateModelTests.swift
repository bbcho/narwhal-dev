import Foundation
import Testing
@testable import NarwhalAppSupport

@Suite("Update model")
struct UpdateModelTests {
    @Test("Semantic versions parse tags and compare numerically")
    func semanticVersions() throws {
        #expect(try SemanticVersion("v1.2.3") == SemanticVersion("1.2.3"))
        #expect(try SemanticVersion("1.10.0") > SemanticVersion("1.9.9"))
        #expect(try SemanticVersion("2.0.0") > SemanticVersion("1.99.99"))
    }

    @Test("Malformed and ambiguous versions are rejected")
    func invalidVersions() {
        for raw in ["", "1", "1.2", "1.2.3.4", "1.02.3", "1.2.-3", "1.2.3-beta"] {
            #expect(throws: SemanticVersionError.self) {
                try SemanticVersion(raw)
            }
        }
    }

    @Test("Only a strictly newer release is offered")
    func availability() throws {
        let pageURL = try #require(URL(string: "https://github.com/bbcho/narwhal-dev/releases/tag/v1.1.0"))
        let current = try SemanticVersion("1.0.0")

        #expect(updateAvailability(
            current: current,
            latest: try SemanticVersion("1.0.0"),
            pageURL: pageURL
        ) == .current)
        #expect(updateAvailability(
            current: current,
            latest: try SemanticVersion("0.9.9"),
            pageURL: pageURL
        ) == .current)
        #expect(updateAvailability(
            current: current,
            latest: try SemanticVersion("1.1.0"),
            pageURL: pageURL
        ) == .newer(version: try SemanticVersion("1.1.0"), pageURL: pageURL))
    }

    @Test("Menu status exposes retry without overlapping checks")
    func menuStatus() throws {
        let pageURL = try #require(URL(string: "https://github.com/bbcho/narwhal-dev/releases"))
        #expect(UpdateMenuStatus.idle.isEnabled)
        #expect(UpdateMenuStatus.checking.isEnabled == false)
        #expect(UpdateMenuStatus.failed.isEnabled)
        #expect(UpdateMenuStatus.available(
            version: try SemanticVersion("2.0.0"),
            pageURL: pageURL
        ).title == "Get Narwhal 2.0.0…")
    }
}
