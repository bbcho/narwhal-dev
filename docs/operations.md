# Operations Runbook

This runbook covers build, install, update, uninstall, logs, smoke tests, and
common failure handling.

## Prerequisites

- macOS 26 or newer.
- Xcode Command Line Tools or a compatible Swift toolchain.
- Homebrew Lua:

```sh
brew install lua
```

The packaging script expects:

```text
/opt/homebrew/opt/lua/lib/liblua.dylib
```

## Build

Run tests:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
```

Build app bundle:

```sh
scripts/build_app_bundle.sh --configuration debug --output .build/narwhal-package-next --replace
```

The package output contains:

```text
.build/narwhal-package-next/Narwhal.app
.build/narwhal-package-next/com.ben.narwhal.plist
```

The app bundle contains:

- `Contents/MacOS/NarwhalApp`
- `Contents/MacOS/narwhalctl`
- `Contents/Resources/DefaultConfig/init.lua`
- `Contents/Frameworks/liblua.dylib`

## Install

Install for the current user:

```sh
scripts/install_local.sh --replace --configuration debug
```

Useful options:

```sh
scripts/install_local.sh --configuration release
scripts/install_local.sh --no-launchctl
scripts/install_local.sh --app-dir .build/install-test/Applications --launch-agents-dir .build/install-test/LaunchAgents --no-launchctl --replace
```

Default install locations:

```text
~/Applications/Narwhal.app
~/Library/LaunchAgents/com.ben.narwhal.plist
```

## Update

Reinstall with replacement:

```sh
scripts/install_local.sh --replace --configuration debug
```

The installer asks the running app to quit through IPC when possible, then boots
out the LaunchAgent, replaces the app and plist, and bootstraps the LaunchAgent
again.

## Uninstall

```sh
scripts/uninstall_local.sh
```

Keep the app bundle but remove LaunchAgent:

```sh
scripts/uninstall_local.sh --keep-app
```

Skip launchctl for test directories:

```sh
scripts/uninstall_local.sh --no-launchctl --app-dir .build/install-test/Applications --launch-agents-dir .build/install-test/LaunchAgents
```

## LaunchAgent

Inspect:

```sh
launchctl print "gui/$(id -u)/com.ben.narwhal"
```

Boot out:

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.ben.narwhal.plist"
```

Bootstrap:

```sh
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.ben.narwhal.plist"
```

## Logs

Primary log:

```text
~/Library/Logs/Narwhal/narwhal.log
```

Follow logs:

```sh
tail -f "$HOME/Library/Logs/Narwhal/narwhal.log"
```

`NARWHAL_LOG_PATH` overrides this path for isolated smoke-test runs. Normal user
launches should use the default private log directory.

Expected healthy startup sequence:

- `NarwhalApp started`
- `Accessibility trusted`
- `Environment refreshed (startup)`
- `Restore state loaded` or `Restore state not found`
- `Registered hotkeys`
- `AX focus observer ready`
- `Display observer ready`
- `Config watcher ready` or skipped because config directory is absent
- `IPC server ready`
- `Drag zones ready`
- `Layout command loop ready`

## Runtime Paths

| Artifact | Path |
|---|---|
| Log | `~/Library/Logs/Narwhal/narwhal.log` |
| IPC socket | `/tmp/narwhal-$(id -u).sock` |
| User config | `~/.config/narwhal/init.lua` |
| Restore state | `~/Library/Application Support/narwhal/state.json` |
| Installed app | `~/Applications/Narwhal.app` |
| LaunchAgent plist | `~/Library/LaunchAgents/com.ben.narwhal.plist` |

## Health Checks

Check config:

```sh
NarwhalApp --check-config
```

Check Accessibility:

```sh
NarwhalApp --check-accessibility
```

Check full environment:

```sh
NarwhalApp --check-environment
```

Print focused window:

```sh
NarwhalApp --focused-window
```

One-shot push left:

```sh
NarwhalApp --push-left
```

Use a test restore path:

```sh
NarwhalApp --restore-state /private/tmp/narwhal-state.json
```

Use a test config:

```sh
NarwhalApp --config /private/tmp/narwhal-init.lua
```

## Smoke Tests

Automated suite:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
```

Package gate:

```sh
scripts/build_app_bundle.sh --configuration debug --output .build/narwhal-package-next --replace
plutil -p .build/narwhal-package-next/Narwhal.app/Contents/Info.plist
plutil -p .build/narwhal-package-next/com.ben.narwhal.plist
otool -L .build/narwhal-package-next/Narwhal.app/Contents/MacOS/NarwhalApp | sed -n '1,4p'
```

Install lifecycle:

```sh
scripts/install_local.sh --no-launchctl --app-dir .build/install-test/Applications --launch-agents-dir .build/install-test/LaunchAgents --replace --configuration debug
scripts/uninstall_local.sh --no-launchctl --app-dir .build/install-test/Applications --launch-agents-dir .build/install-test/LaunchAgents
```

Startup/shutdown smoke:

```sh
scripts/smoke_startup_shutdown.sh
```

Config hot-reload smoke:

```sh
scripts/smoke_config_hot_reload.sh
```

See [sprint-gates.md](sprint-gates.md) for complete gate criteria.

## Troubleshooting

### Accessibility Not Trusted

Symptom:

```text
Accessibility not trusted
```

Fix:

1. Open System Settings.
2. Go to Privacy & Security, Accessibility.
3. Grant permission to the exact executable or app bundle being run.
4. Restart Narwhal.

Different builds may need separate permissions.

### IPC Failed

Check whether the socket exists:

```sh
ls -l "/tmp/narwhal-$(id -u).sock"
```

Check whether the LaunchAgent is running:

```sh
launchctl print "gui/$(id -u)/com.ben.narwhal"
```

Read logs:

```sh
tail -n 100 "$HOME/Library/Logs/Narwhal/narwhal.log"
```

If a stale socket remains after a crash:

```sh
rm "/tmp/narwhal-$(id -u).sock"
```

Then restart the app.

### Active Space Unavailable

Narwhal reads the active macOS Space through private CoreGraphics symbols. If the
symbol is unavailable or returns `0`, layout services do not start.

Check:

```sh
NarwhalApp --check-environment
tail -n 80 "$HOME/Library/Logs/Narwhal/narwhal.log"
```

### Config Reload Failed

Logs show the exact parse or Lua error:

```sh
tail -n 80 "$HOME/Library/Logs/Narwhal/narwhal.log"
```

The previous valid config remains active. Fix the Lua file and save it again.

### Hotkey Does Nothing

Check:

- Accessibility is trusted.
- The app is running.
- The hotkey is registered in `~/Library/Logs/Narwhal/narwhal.log`.
- No other app has captured the same global hotkey.
- The key is supported by `HotkeyManager`.

### Layout Write Fails

Common causes:

- Target window disappeared.
- Window is not resizable.
- App imposes a minimum size larger than the solved tile.
- AX did not converge after frame writes.

Narwhal records observed minimum-size constraints when a frame is clamped and
retries once. If the layout remains unsatisfiable, the planned layout is not
committed.

### Restore Looks Wrong After Monitor Changes

Restore prefers display fingerprint and falls back to display slot. If a display
cannot be fingerprinted, slot order may decide the match. Reset layout memory if
the physical monitor setup changed substantially:

```sh
narwhalctl reset
```
