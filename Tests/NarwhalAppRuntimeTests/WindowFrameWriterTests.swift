import CoreGraphics
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@MainActor
@Suite("Window frame writer")
struct WindowFrameWriterTests {
    @Test("Terminal bounds script uses integral WindowServer coordinates")
    func terminalScript() throws {
        let script = try #require(terminalBoundsAppleScript(
            windowID: WindowID(raw: 42),
            frame: CGRect(x: 0.2, y: 30.4, width: 1_503.6, height: 780.7)
        ))

        #expect(script.contains("first window whose id is 42"))
        #expect(script.contains("set bounds of targetWindow to {0, 30, 1504, 811}"))
    }

    @Test("Terminal uses its exact bounds adapter and verifies both readbacks")
    func terminalAdapter() async {
        let target = CGRect(x: 0, y: 30, width: 1_504, height: 781)
        var accessibilityWriteCount = 0
        var terminalWriteCount = 0
        var requestedFrame: CGRect?
        let writer = WindowFrameWriter(
            writeAccessibility: { _, _ in
                accessibilityWriteCount += 1
                return .failed(.invalidFrame(.null))
            },
            writeTerminal: { _, frame in
                terminalWriteCount += 1
                requestedFrame = frame
                return .success(())
            },
            readback: { _ in
                .success(WindowFrameReadback(
                    accessibility: target,
                    windowServer: target
                ))
            }
        )

        switch await writer.setFrame(metadata(bundleID: "com.apple.Terminal"), to: target) {
        case .converged(let actual):
            #expect(actual == target)
        case .constrained, .clamped, .failed:
            Issue.record("Expected an exact Terminal frame")
        }
        #expect(accessibilityWriteCount == 0)
        #expect(terminalWriteCount == 1)
        #expect(requestedFrame == target)
    }

    @Test("Automation failure does not fall back to Accessibility")
    func automationFailure() async {
        var accessibilityWriteCount = 0
        var readbackCount = 0
        let writer = WindowFrameWriter(
            writeAccessibility: { _, _ in
                accessibilityWriteCount += 1
                return .converged(actual: .zero)
            },
            writeTerminal: { window, _ in
                .failure(.automationFailed(bundleID: window.bundleID.raw, message: "denied"))
            },
            readback: { _ in
                readbackCount += 1
                return .failure(.windowServerFrameUnavailable(WindowID(raw: 42)))
            }
        )

        switch await writer.setFrame(
            metadata(bundleID: "com.apple.Terminal"),
            to: CGRect(x: 0, y: 30, width: 1_504, height: 781)
        ) {
        case .failed(.automationFailed(let bundleID, _)):
            #expect(bundleID == "com.apple.Terminal")
        case .converged, .constrained, .clamped, .failed:
            Issue.record("Expected the Automation failure")
        }
        #expect(accessibilityWriteCount == 0)
        #expect(readbackCount == 0)
    }

    @Test("Generic Accessibility success requires matching WindowServer geometry")
    func genericReadbackAgreement() async {
        let target = CGRect(x: 0, y: 30, width: 1_504, height: 781)
        let windowServer = CGRect(x: 0, y: 30, width: 1_500, height: 781)
        var accessibilityWriteCount = 0
        var terminalWriteCount = 0
        var readbackCount = 0
        let writer = WindowFrameWriter(
            writeAccessibility: { _, frame in
                accessibilityWriteCount += 1
                return .converged(actual: frame)
            },
            writeTerminal: { _, _ in
                terminalWriteCount += 1
                return .success(())
            },
            readback: { _ in
                readbackCount += 1
                return .success(WindowFrameReadback(
                    accessibility: target,
                    windowServer: windowServer
                ))
            }
        )

        switch await writer.setFrame(metadata(bundleID: "org.mozilla.firefox"), to: target) {
        case .failed(.frameReadbackDisagreed(let expected, let accessibility, let visible)):
            #expect(expected == target)
            #expect(accessibility == target)
            #expect(visible == windowServer)
        case .converged, .constrained, .clamped, .failed:
            Issue.record("Expected AX and WindowServer disagreement")
        }
        #expect(accessibilityWriteCount == 1)
        #expect(terminalWriteCount == 0)
        #expect(readbackCount == 4)
    }

    @Test("Confirmed generic constraint returns after one matching visible readback")
    func genericConstraintReadback() async {
        let target = CGRect(x: 0, y: 30, width: 1_504, height: 781)
        let constrained = CGRect(x: 0, y: 30, width: 1_500, height: 781)
        var readbackCount = 0
        var settleCount = 0
        let writer = WindowFrameWriter(
            writeAccessibility: { _, _ in
                .constrained(actual: constrained)
            },
            writeTerminal: { _, _ in
                .failure(.invalidFrame(.null))
            },
            readback: { _ in
                readbackCount += 1
                return .success(WindowFrameReadback(
                    accessibility: constrained,
                    windowServer: constrained
                ))
            },
            settle: {
                settleCount += 1
            }
        )

        switch await writer.setFrame(metadata(bundleID: "org.mozilla.firefox"), to: target) {
        case .constrained(let actual):
            #expect(actual == constrained)
        case .converged, .clamped, .failed:
            Issue.record("Expected the confirmed constrained frame")
        }
        #expect(readbackCount == 1)
        #expect(settleCount == 0)
    }

    private func metadata(bundleID: String) -> WindowMetadata {
        WindowMetadata(
            id: WindowID(raw: 42),
            bundleID: BundleID(raw: bundleID),
            title: "Test",
            role: "AXWindow",
            pid: 101,
            frame: CGRect(x: 20, y: 40, width: 800, height: 600),
            isResizable: true,
            isMinimized: false
        )
    }
}
