# Production Gates

This is the authoritative verification matrix. Historical one-off results belong
in CI logs and Git history, not in this file.

## Pull Request Gate

Run from the repository root:

```sh
bash -n scripts/*.sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache \
  swift test --disable-sandbox
scripts/build_app_bundle.sh \
  --configuration debug \
  --output .build/narwhal-package-next \
  --replace
scripts/verify_app_bundle.sh \
  --app .build/narwhal-package-next/Narwhal.app
```

Pass criteria:

- No test failures. IPC tests must actually bind and communicate; sandbox-denied
  socket tests must be rerun in a permitted environment.
- Shell syntax is valid.
- The bundle has the expected identifier, version, build, minimum macOS version,
  architecture, nested signatures, private Lua linkage, and third-party notice.
- CI runs unit/integration tests, AddressSanitizer, ThreadSanitizer, and an arm64
  artifact build.

## Trusted Runtime Gate

Run from a terminal or runner whose exact process identity is approved for
Accessibility:

```sh
scripts/smoke_startup_shutdown.sh
scripts/smoke_startup_recovery.sh
scripts/smoke_startup_failure_matrix.sh
scripts/smoke_config_hot_reload.sh
scripts/smoke_packaged_app.sh
scripts/smoke_install_upgrade.sh
scripts/smoke_runtime_soak.sh --duration-seconds 300
```

These gates prove:

- complete startup and graceful restore flush on quit;
- strict config validation, normal-startup fallback, hot recovery, corrupt-state
  quarantine, and private quarantine permissions;
- reverse-order rollback at every runtime service boundary;
- last-good config preservation after an invalid hot reload;
- packaged app and CLI behavior;
- staged install, versioned replacement, retained previous app, and uninstall;
- repeated diagnostics and IPC commands with no dropped logs, no unexpected
  process exit, and resident memory below the explicit soak ceiling.

Any missing Accessibility trust is a failure, not a skip.

## Visual and Real-App Gate

```sh
scripts/live_verify_all.sh
```

The script runs AppKit and real-app phases sequentially. A pass requires both
suites to start, execute at least one test, report no skip, and complete with no
issue. Silence while AppKit owns the main loop is not evidence of a hang; wait
for the status output.

The real-app phase must open fresh verification windows and cover:

- Chrome;
- Firefox;
- System Settings;
- Terminal;
- mixed Chrome/Firefox manual tile resize;
- three-window vertical stacks in Chrome and Firefox.

Resize and border cases verify both AX-applied geometry and the WindowServer
visible frame. Existing browser windows must be excluded so a stale session
window cannot satisfy the test. Do not remove, narrow, or skip a failing case.

For focus borders, tiled borders, overlays, menu chrome, save panels, or other
visible layout, add a focused AppKit geometry/pixel/screenshot verifier as well
as model tests. Compile and startup coverage alone is not visual proof.

## Release Gate

Before tagging:

1. The worktree and index are clean.
2. Pull request, trusted runtime, and live real-app gates pass on the release
   commit.
3. `Packaging/NarwhalInfo.plist` contains the intended semantic version.
4. The repository has an explicit project license chosen by the owner.
5. Release secrets and permissions described in [release.md](release.md) are
   configured.

Tag the exact commit as `vMAJOR.MINOR.PATCH`. The release workflow must then
produce and publish a Developer ID-signed, notarized, stapled, Gatekeeper-accepted
arm64 ZIP, its dSYM ZIP, `release.json`, and `SHA256SUMS`.

The release fails if signing, notarization, stapling, Gatekeeper, architecture,
version, clean-tree, exact-tag, or checksum requirements are not satisfied.
