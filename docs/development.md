# Developer Guide

This guide is for working on the codebase locally.

## Setup

Requirements:

- macOS 26 or newer.
- Xcode Command Line Tools or compatible Xcode.
- Swift package manager.
- Homebrew Lua 5.5:

```sh
brew install lua
```

The package links Lua through the `CLua` system library target. Packaging copies
Homebrew's `liblua.dylib` into the app bundle and rewrites the app executable to
load it from `@executable_path/../Frameworks/liblua.dylib`.

## Repository Layout

```text
Package.swift
DefaultConfig/init.lua
Packaging/
Sources/
  CLua/
  NarwhalApp/
  NarwhalAppSupport/
  NarwhalCore/
  NarwhalCtl/
  NarwhalIPC/
Tests/
docs/
scripts/
```

## Build

Debug build:

```sh
swift build
```

Specific product:

```sh
swift build --product NarwhalApp
swift build --product NarwhalCtl
```

Package app bundle:

```sh
scripts/build_app_bundle.sh --configuration debug --output .build/narwhal-package-next --replace
```

## Test

Preferred command:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
```

The explicit module cache path avoids Swift/Clang cache permission problems in
sandboxed or agent-driven environments.

Run selected tests:

```sh
swift test --filter ConfigTests
swift test --filter IPCTransportTests
swift test --filter MVPLayoutTests
```

## Test Strategy

The highest-value tests are pure core tests:

- Tree insertion and slot invariants.
- Layout solver exactness and minimum-size adjustment.
- Command application and failure cases.
- Config parser and renderer round trips.
- Restore projection/remap and validation.
- Focus navigation.
- Environment coalescing.
- AX echo suppression.
- IPC DTO wire shape.

Shell-support tests cover:

- Restore manager load/save/scheduler behavior.
- Service lifecycle rollback.
- IPC transport connection behavior.

Manual and script smokes cover AppKit, Accessibility, LaunchAgent, real display
state, hotkeys, and event taps.

Live AppKit verifiers cover visible UI and layout behavior that unit tests cannot
prove. Run the full live suite before shipping focus-border, tiled-border,
overlay, command workflow, Space, or display changes:

```sh
scripts/live_verify_all.sh
```

Live verifier code lives in the `NarwhalLiveVerifierTests` target and is compiled
behind `NARWHAL_ENABLE_VERIFIERS`; use the script instead of passing `--verify-*`
flags to a normal app build.

The live command workflow verifier creates real AppKit windows and runs command
families through the core planning path for 0 through 6 windows. It verifies
actual frame application, focus cycling/focus direction, tiled-border visibility,
focus-border visibility, and window-server stacking. True multi-display movement
is verified only when the machine has at least two usable displays; otherwise the
live suite reports that segment as skipped. Multi-Space state isolation is covered
by the Space focus recovery verifier with real AppKit windows and separate
workspace model state. Display-change focus preservation is covered by a live
verifier that clears tiled borders while AX focus is unavailable and then checks
that the focus border remains visible above its target window.

## Coding Guidelines

Preserve the current architecture:

- Put domain behavior in `NarwhalCore` as value types and pure functions.
- Keep AppKit, AX, Lua, filesystem, launchd, and socket effects in shell targets.
- Validate untrusted data once at the boundary.
- Return `Result` for expected domain failures.
- Throw for infrastructure failures in shell code.
- Commit `World` changes only after shell effects that must succeed have
  succeeded.
- Keep service startup and shutdown explicit and reversible.

Avoid:

- Hidden reads of global state in core functions.
- New mutable manager classes where a value plus functions works.
- Defaulting unknown boundary data to a domain lie.
- New config knobs without a current behavior that uses them.
- Broad catch-and-ignore error handling around lifecycle code.

## Core Change Checklist

Before changing `NarwhalCore`:

1. Identify the invariant or command behavior being changed.
2. Add or update direct example tests.
3. Add property-style coverage if the change affects tree shape, ordering,
   restore round trips, or solver invariants.
4. Keep public errors explicit enough for IPC and logs.
5. Confirm default config still round-trips:

```sh
swift test --filter ConfigTests
```

## Shell Change Checklist

Before changing `NarwhalApp`, `NarwhalIPC`, or `NarwhalAppSupport`:

1. Identify the effect boundary: AX, AppKit, Lua, file, socket, timer, launchd,
   or logging.
2. Decide whether failure should throw, return `Result`, log and continue, or
   terminate startup.
3. Make resource ownership explicit. If a service starts something, its stop
   closure must release it.
4. Keep `@MainActor` on AppKit-facing state.
5. Add support tests where the behavior can be tested without a real app run.
6. Add or update a smoke script when the behavior needs the OS.

## Config Changes

When adding a config field:

1. Add the immutable field to `Config`.
2. Add default value in `Config.default`.
3. Add rendering support in `DefaultConfigLua`.
4. Add parsing support in `ConfigParsing`.
5. Update `DefaultConfig/init.lua`.
6. Update `Tests/NarwhalCoreTests/ConfigTests.swift`.
7. Update [Configuration reference](configuration.md).

The test `Bundled init.lua exactly mirrors Swift Config.default` should fail if
the bundled Lua and Swift default drift.

## IPC Changes

When adding an IPC command:

1. Add a case to `IPCCommandDTO`.
2. Update encode/decode shape.
3. Update `IPCDTOTests`.
4. Add shell handling in `App.handleIPCCommand`.
5. Add CLI parsing if the command should be user-facing through `narwhalctl`.
6. Update [Command reference](commands.md).

## Packaging Changes

Packaging script:

```text
scripts/build_app_bundle.sh
```

Install script:

```text
scripts/install_local.sh
```

Uninstall script:

```text
scripts/uninstall_local.sh
```

Any packaging change should run:

```sh
scripts/build_app_bundle.sh --configuration debug --output .build/narwhal-package-next --replace
plutil -p .build/narwhal-package-next/Narwhal.app/Contents/Info.plist
plutil -p .build/narwhal-package-next/com.ben.narwhal.plist
otool -L .build/narwhal-package-next/Narwhal.app/Contents/MacOS/NarwhalApp | sed -n '1,4p'
```

## Release Checklist

For a local release candidate:

1. Run the full automated suite.
2. Build a package.
3. Run the local install lifecycle gate.
4. Install to user paths with LaunchAgent.
5. Verify `launchctl print`.
6. Run `narwhalctl reset`.
7. Run manual tiling/focus/swap/reset smoke.
8. Check `~/Library/Logs/Narwhal/narwhal.log`.

See [Sprint gates](sprint-gates.md) for detailed acceptance criteria.
