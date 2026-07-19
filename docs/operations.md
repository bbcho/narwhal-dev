# Operations Runbook

This runbook covers local builds, installation, recovery, diagnostics, and the
production release gates.

## Prerequisites

- macOS 26 or newer.
- Xcode or Command Line Tools with a compatible Swift toolchain.
- Homebrew Lua 5.5 at `/opt/homebrew/opt/lua/lib/liblua.dylib`.
- Accessibility approval for the exact app or terminal-hosted process that uses
  the Accessibility APIs.

Install Lua with `brew install lua`.

## Build and Verify a Bundle

Run the automated suite:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache \
  swift test --disable-sandbox
```

Build and inspect a development bundle:

```sh
scripts/build_app_bundle.sh \
  --configuration debug \
  --output .build/narwhal-package-next \
  --replace
scripts/verify_app_bundle.sh \
  --app .build/narwhal-package-next/Narwhal.app
```

The bundle contains the app, `narwhalctl`, the default config, the icon assets,
the Lua runtime, and the Lua license notice. Lua is linked from inside the app;
the packaged executable must not depend on the Homebrew path.

## Install

Install a local build:

```sh
scripts/install_local.sh --replace --configuration release
```

The installer stages and verifies the new bundle before replacing
`~/Applications/Narwhal.app`. On replacement, the former bundle is retained as
`~/Applications/Narwhal.app.previous`. A failed swap restores the former bundle.
The installer neither resets Accessibility nor enables Launch at Login.

Use Narwhal's menu item **Launch at Login** to register or unregister the app
through `SMAppService`. If macOS requires approval, the menu opens Login Items in
System Settings.

For an isolated install lifecycle test:

```sh
scripts/smoke_install_upgrade.sh
```

## Updates and Rollback

**Check for Updates…** is user initiated. Narwhal reads the latest stable GitHub
release metadata and, when a newer semantic version exists, changes the menu
item to **Get Narwhal VERSION…**. Selecting it opens the GitHub release page.
Narwhal never downloads or executes an update.

Install a downloaded, verified repo build with the replacement command above.
If the new build does not work, quit it and restore the retained
`Narwhal.app.previous` bundle in Finder. Verify the restored bundle before
opening it:

```sh
codesign --verify --deep --strict "$HOME/Applications/Narwhal.app"
```

See [Release process](release.md) for Developer ID, notarization, and published
artifact requirements.

## Uninstall

```sh
scripts/uninstall_local.sh
```

The script requests a graceful IPC quit, unregisters the `SMAppService` login
item, and removes both the current and retained previous app. Use `--keep-app`
to unregister Launch at Login without removing the app. Accessibility approval
is not reset.

## Logs and Support Bundles

The primary log is:

```text
~/Library/Logs/Narwhal/narwhal.log
```

Narwhal rotates at 5 MiB, retains three generations, and enforces owner-only
permissions. Runtime logging redacts window titles, bundle identifiers, and
absolute paths before writing to unified logging, stderr, or files.

Use **Copy Diagnostics** for the current privacy-reviewed JSON status. Use
**Export Support Bundle…** to create a ZIP containing only `diagnostics.json`
and up to 4 MiB of redacted current/rotated logs. It does not include config or
restore state. Review the ZIP before sharing it.

`NARWHAL_LOG_PATH` is supported for isolated smoke runs. Do not use it in a
normal installation.

## Runtime Paths

| Artifact | Path |
|---|---|
| App | `~/Applications/Narwhal.app` |
| Previous app | `~/Applications/Narwhal.app.previous` |
| Config | `~/.config/narwhal/init.lua` |
| Restore state | `~/Library/Application Support/narwhal/state.json` |
| Restore backup | `~/Library/Application Support/narwhal/state.json.previous` |
| Log | `~/Library/Logs/Narwhal/narwhal.log` |
| IPC socket | `/tmp/narwhal-$(id -u).sock` |

Invalid restore files are moved beside the primary file as
`state.json.corrupt-IDENTIFIER` with owner-only permissions. A valid backup is
restored automatically; otherwise Narwhal starts with an empty layout and shows
a warning. State from a future schema is left untouched and the runtime remains
degraded until a compatible build is installed.

## Health Checks

Use the binaries inside the installed app for an unambiguous process identity:

```sh
app="$HOME/Applications/Narwhal.app/Contents/MacOS/NarwhalApp"
ctl="$HOME/Applications/Narwhal.app/Contents/MacOS/narwhalctl"

"$app" --check-config
"$app" --check-accessibility
"$app" --check-environment
"$ctl" status
"$ctl" status --json
```

Normal startup falls back to built-in defaults when a user config is invalid;
`--check-config` remains strict and exits nonzero. Saving a corrected config
hot-reloads it without restarting the app.

A healthy startup reaches these log events:

- `Accessibility trusted`
- `Environment refreshed (startup)`
- `AX observer ready; notification fast path active`
- `Display observer ready`
- `IPC server ready`
- `Layout command loop ready`

## Verification Gates

Run the current gate commands from [Production gates](sprint-gates.md). In
particular, `scripts/live_verify_all.sh` must run from an Accessibility-trusted
runner. A skipped live suite, a suite that opens no real apps, or a run with no
matching tests is a failure.

The live gate manipulates real Chrome, Firefox, System Settings, and Terminal
windows. Close sensitive work and stop an installed Narwhal process first.

## Troubleshooting

### Accessibility is not trusted

Approval belongs to the exact executable identity making AX calls. Grant access
in System Settings → Privacy & Security → Accessibility, restart that runner,
and rerun a real AX frame-write verifier. Ad-hoc rebuilds can change identity;
use a stable `NARWHAL_SIGNING_IDENTITY` for repeated installed-app testing.

### IPC is unavailable

Confirm Narwhal is running and inspect the socket and log:

```sh
ls -l "/tmp/narwhal-$(id -u).sock"
tail -n 100 "$HOME/Library/Logs/Narwhal/narwhal.log"
```

If no Narwhal process owns a stale socket, remove that exact socket and restart
the app.

### Config reload failed

The previous valid in-memory config remains active. Fix and save the Lua file,
then look for `Config reload completed (file watcher)`.

### A layout write fails

The window may have disappeared, may not be resizable, may enforce a larger
minimum size, or may not converge after AX writes. Narwhal records observed
constraints and retries once; it does not commit a layout whose writes fail.
Use `narwhalctl status` and export a support bundle.

### Restore is wrong after a display change

Restore matches display fingerprints first and slots second. A substantial
physical display change may make the old layout unsuitable. Reset layout memory
with `narwhalctl reset` after preserving any support evidence you need.
