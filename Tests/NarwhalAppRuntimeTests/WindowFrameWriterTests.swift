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

    @Test(
        "Terminal bounds compensate for the source display y-origin",
        arguments: [-120.0, 0.0, 98.0] as [CGFloat]
    )
    func terminalSourceDisplayOffset(sourceMinY: CGFloat) {
        let sourceDisplay = CGRect(x: 3_008, y: sourceMinY, width: 1_512, height: 982)
        let sourceWindow = CGRect(x: 3_100, y: sourceMinY + 52, width: 900, height: 700)
        let target = CGRect(x: 24, y: 54, width: 1_263, height: 656)

        let adjusted = terminalAppleScriptFrame(
            target: target,
            sourceFrame: sourceWindow,
            displayFrames: [sourceDisplay]
        )

        #expect(adjusted == target.offsetBy(dx: 0, dy: -sourceMinY))
        #expect(adjusted.size == target.size)
    }

    @Test("Terminal bounds use the source display with the largest intersection")
    func terminalSourceDisplaySelection() {
        let target = CGRect(x: 24, y: 54, width: 1_263, height: 656)
        let adjusted = terminalAppleScriptFrame(
            target: target,
            sourceFrame: CGRect(x: 900, y: 240, width: 800, height: 600),
            displayFrames: [
                CGRect(x: 0, y: 0, width: 1_000, height: 900),
                CGRect(x: 1_000, y: 200, width: 1_000, height: 900)
            ]
        )

        #expect(adjusted == target.offsetBy(dx: 0, dy: -200))
    }

    @Test("Terminal bounds stay global when the source display is unavailable")
    func terminalMissingSourceDisplay() {
        let target = CGRect(x: 24, y: 54, width: 1_263, height: 656)

        #expect(terminalAppleScriptFrame(
            target: target,
            sourceFrame: CGRect(x: 4_500, y: 2_000, width: 800, height: 600),
            displayFrames: [CGRect(x: 0, y: 0, width: 3_008, height: 1_692)]
        ) == target)
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

    @Test("Confirmed generic constraint survives the read-only observation window")
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
        #expect(readbackCount == 4)
        #expect(settleCount == 3)
    }

    @Test("A moving Accessibility readback does not persist a stale constraint")
    func movingReadbackDoesNotPersistConstraint() async {
        let target = CGRect(x: 40, y: 74, width: 2_406, height: 740)
        let initiallyObserved = CGRect(x: 40, y: 30, width: 2_103, height: 872)
        let laterObserved = CGRect(x: 40, y: 74, width: 2_200, height: 740)
        var readbackCount = 0
        let writer = WindowFrameWriter(
            writeAccessibility: { _, _ in
                .clamped(
                    actual: initiallyObserved,
                    observed: WindowConstraints(minHeight: 872)
                )
            },
            writeTerminal: { _, _ in
                .failure(.invalidFrame(.null))
            },
            readback: { _ in
                readbackCount += 1
                let frame = readbackCount == 1 ? initiallyObserved : laterObserved
                return .success(WindowFrameReadback(
                    accessibility: frame,
                    windowServer: frame
                ))
            }
        )

        switch await writer.setFrame(metadata(bundleID: "org.mozilla.firefox"), to: target) {
        case .constrained(let actual):
            #expect(actual == laterObserved)
        case .converged, .clamped, .failed:
            Issue.record("Expected motion to invalidate the stale minimum")
        }
        #expect(readbackCount == 4)
    }

    @Test("A stable Accessibility clamp remains a confirmed constraint")
    func stableReadbackPreservesConstraint() async {
        let target = CGRect(x: 40, y: 74, width: 2_406, height: 740)
        let actual = CGRect(x: 40, y: 74, width: 2_406, height: 780)
        let observed = WindowConstraints(minHeight: 780)
        var readbackCount = 0
        let writer = WindowFrameWriter(
            writeAccessibility: { _, _ in
                .clamped(actual: actual, observed: observed)
            },
            writeTerminal: { _, _ in
                .failure(.invalidFrame(.null))
            },
            readback: { _ in
                readbackCount += 1
                return .success(WindowFrameReadback(
                    accessibility: actual,
                    windowServer: actual
                ))
            }
        )

        switch await writer.setFrame(metadata(bundleID: "org.mozilla.firefox"), to: target) {
        case .clamped(let settled, let constraints):
            #expect(settled == actual)
            #expect(constraints == observed)
        case .converged, .constrained, .failed:
            Issue.record("Expected the stable clamp to remain confirmed")
        }
        #expect(readbackCount == 4)
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
