For UI, overlay, focus-border, window-chrome, or visual layout changes, do not treat `swift test` and smoke scripts as sufficient by themselves. Add or run a verification that exercises the actual UI/layout behavior being changed, such as an AppKit geometry test, screenshot/manual visual check, or focused harness that proves the visible layout/state. In the final response, state exactly what covered the visual behavior and what was only compile/startup coverage.

Session lessons:

- Run every test command under a command-scoped `/usr/bin/caffeinate -dimsu` assertion so the display, system, and disks stay awake for exactly the duration of the test process. Do not leave a background `caffeinate` process running after tests finish. When a script already provides the assertion, do not start a redundant second wrapper.
- For real window-resize work, the live verifier must exercise real program windows. The minimum real-app coverage is Chrome, Firefox, System Settings, Terminal, the mixed Chrome/Firefox manual tile-resize test, and the 3-window vertical stack tests for Chrome and Firefox. Mock or pretend windows do not prove this behavior.
- A skipped live verifier is a failure for this project. "No matching test cases were run", skipped tests, missing real-app suite startup, or real apps not actually opening must not be reported as success.
- Do not remove or narrow failing live tests to make a run pass. If a live test fails, either fix the app/verifier behavior or report the failure clearly.
- Chrome may reuse stale session windows when launched with plain `open -a`. Real Chrome verifier cases should create fresh verification windows, exclude browser windows that existed before the test, and verify the selected AX window is the new real window.
- Browser window sizes are not just monitor-size problems. On large displays, failures can still come from app-reported minimum sizes, stale window selection, or browser chrome constraints. Check the actual AX and WindowServer frames before concluding the display is too small.
- When testing border or resize behavior, verify both the AX-applied frame and the WindowServer-visible frame. Passing model tests or compile checks alone is not visual proof.
- Run live verifier commands from an Accessibility-trusted runner. In this repo, Terminal-hosted runs are the reliable path when sandboxed Codex/kitty trust is questionable.
- Live verifier output can be buffered for a long time, especially during AppKit focus workflows. Poll the status file or wait long enough before treating silence as a hang; do not kill a run only because stdout has not flushed.
- `scripts/live_verify_all.sh` is the full live gate. It should run AppKit and real-app phases sequentially so independent live tests do not fight over windows.
- Commit frequently after verified chunks, and keep commits scoped to the issue being fixed.

Accessibility/TCC lessons:

- Accessibility trust is attached to the exact process identity that calls AX APIs. Do not assume "the terminal is trusted" means every app bundle, SwiftPM helper, or rebuilt executable is trusted.
- When running `swift run`, `swift test`, or a live verifier from Terminal, the trusted runner may be Terminal and/or SwiftPM's test helper path rather than `Narwhal.app`. It is normal for Narwhal not to appear in the Accessibility list in that mode.
- A live verifier must not hide AX trust failures behind skips. If Accessibility is missing, the real-app verifier should fail clearly or the operator should fix trust and rerun; skip is fail for this repo.
- Do not add an `AXIsProcessTrusted` guard that prevents real apps from opening or makes the live verifier report success without doing AX frame writes. The reliable proof is real AX writes plus WindowServer frame confirmation.
- If Accessibility was working and suddenly is not, first identify which binary is asking for trust. Check recent TCC/log output and the actual runner path before resetting random entries.
- Rebuilding with ad-hoc signing changes the code identity and can invalidate prior Accessibility approval. For installed app testing, prefer a stable signing identity via `NARWHAL_SIGNING_IDENTITY`; `scripts/build_app_bundle.sh` documents the stable self-signed path.
- `scripts/install_local.sh` resets Accessibility for `com.ben.narwhal` by default. That affects the installed app bundle, not necessarily Terminal-hosted SwiftPM verifier runs.
- Toggling Terminal or kitty in System Settings -> Privacy & Security -> Accessibility only affects that terminal runner. Toggling Narwhal affects the installed Narwhal bundle. Do not conflate those trust states.
- If the UI claims a runner is trusted but AX still fails, restart the trusted runner and rerun a small real AX frame-write verifier. Do not trust the checkbox alone.
- Repeated `codesign` or CodeSigningHelper prompts are a sign that macOS is recomputing code identity/TCC requirements. Avoid churning signing settings while debugging AX; stabilize the identity first, then test.
