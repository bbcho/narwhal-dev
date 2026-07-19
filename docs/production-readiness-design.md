# Production Readiness Design

This work turns Narwhal's tested window-management core into a recoverable,
distributable application. It does not change layout semantics. The release
channel is direct distribution for Apple silicon because Narwhal depends on
private macOS Space and window-ordering symbols that are not eligible for the
Mac App Store.

## Invariants

- A malformed user config, corrupt restore file, unavailable private symbol, or
  failed runtime service must not make the menu-bar app disappear. Window
  mutations remain disabled until their prerequisites are healthy, while
  recovery and quit actions remain available.
- Recovery never destroys the only copy of user data. Invalid restore files are
  quarantined, the last valid snapshot is retained separately, and an empty
  state is used only with an explicit recorded recovery outcome.
- Every released restore schema remains readable through a versioned migration
  chain. Future schemas fail visibly without being overwritten.
- Normal termination waits for the newest scheduled restore write. A bounded
  timeout may end shutdown, but an older write must never replace newer state.
- Window titles, bundle identifiers, and user paths are private support data.
  Default release logs and exported diagnostics do not contain them.
- Launch at Login is controlled by the user through `SMAppService`; release
  installation never resets Accessibility approval or writes a LaunchAgent into
  the user's Library.
- Release artifacts are versioned once, built for an explicit architecture,
  signed with Developer ID, notarized, stapled, assessed by Gatekeeper, and
  accompanied by checksums and dSYMs.
- The live release gate runs the actual AppKit and real-app suites without skips
  and checks both AX-applied and WindowServer-visible frames.

## Data model

Pure values are added only where they name recovery or release decisions:

- `RestoreLoadOutcome`: missing, loaded, recovered from backup, recovered empty
  after quarantining invalid state, or incompatible with a future schema.
- `RestoreRecovery`: the primary failure, optional backup failure, and
  quarantined filename without a user directory path.
- `RuntimeReadiness`: operational, waiting for Accessibility, or degraded with
  an actionable reason.
- `ReleaseVersion`: validated semantic display version plus monotonically
  increasing integer build version.
- `UpdateAvailability`: current, newer release, or an explicit expected failure.

No generic manager, repository, coordinator, or service-locator layer is added.

## Core and shell boundaries

```text
state bytes -> decode -> migrate -> validate ---------------------- [CORE]
     disk -> primary/backup selection -> quarantine/write ---------- [SHELL]

startup results -> readiness/recovery presentation ---------------- [CORE]
 AX/AppKit/SMAppService/menu actions ------------------------------- [SHELL]

release tag + build -> validated version values ------------------- [CORE]
 SwiftPM/codesign/notarytool/stapler/spctl/checksum ---------------- [SHELL]

release JSON -> decode + version comparison ----------------------- [CORE]
 URLSession + AppKit presentation --------------------------------- [SHELL]
```

The restore primary and backup are separate atomic files. Updating them is not a
multi-file transaction: the primary is authoritative, while the backup is a
best-effort last-known-good snapshot. Save ordering remains serialized by the
existing actor and task tail.

## Failure contracts

- Restore decoding and migration return `Result` because incompatible or corrupt
  user data is expected at a persistence boundary.
- Restore filesystem operations throw infrastructure errors. The shell converts
  corrupt-data errors into `RestoreLoadOutcome` only after preserving the bad
  file; it does not convert permission or disk failures into success.
- Normal startup config failure activates built-in defaults and degraded status.
  `--check-config` remains strict and returns a non-zero exit status.
- Runtime service startup failure rolls back partially started effects, preserves
  the independently owned menu, and records a retryable degraded state.
- Login-item registration and update checks report explicit errors in the menu
  and log; neither failure blocks window management.
- Release scripts fail on missing identity, invalid version, unexpected
  architecture, signing/notarization error, Gatekeeper rejection, or checksum
  mismatch.

## State and concurrency

- `WorldActor` remains the sole owner of layout state.
- `RestoreFileStore` remains the sole serialized restore filesystem actor.
- AppKit, menu, permission, onboarding, and `SMAppService` state remain on the
  main actor.
- Update network I/O uses one structured task owned by the app delegate; a newer
  request cancels the previous request and UI changes return to the main actor.
- Termination uses AppKit's terminate-later handshake and one main-actor task to
  await restore completion before replying.
- Release and CI tooling is sequential shell orchestration; no background job
  mutates the same artifact.

## Persistence and schema evolution

Schema migrations are pure functions with one step per historical version. A
decoder first reads the versioned value, migrates it to the current schema, then
validates the result. Released fixture files are permanent compatibility tests.

Before replacing a valid primary snapshot, the current valid primary is copied
atomically to `state.json.previous`. If primary loading fails, Narwhal attempts
the backup. An invalid primary is renamed to a unique quarantine filename. A
future-schema file is left untouched and keeps the app in recovery mode.

## Observability and privacy

Operational logs keep event names, result codes, counts, durations, window IDs,
and frames. Window titles, bundle identifiers, full config/state/log paths, and
raw config content are excluded from release logs. A user-initiated support
bundle contains the existing privacy-reviewed diagnostics DTO, redacted logs,
version metadata, and no remote transmission.

Release builds archive dSYMs. Narwhal does not add automatic telemetry or remote
crash upload in this change; users explicitly provide a support bundle or macOS
crash report when requesting support.

## Distribution and updates

The supported production artifact is an arm64 Developer ID application for
macOS 26 or newer. The build consumes an explicit Lua dylib and records its
SHA-256 in the release manifest. The release pipeline produces a notarized ZIP,
dSYM ZIP, checksums, and release metadata.

The in-app update check is user initiated. It reads the latest GitHub release
metadata, compares validated versions, and opens the release page for a newer
Developer ID-signed and notarized artifact. Narwhal does not download or execute
an update itself, avoiding a second privileged mutation path.

## Verification

Focused tests:

- Every supported restore fixture migrates to the current value.
- Migration is idempotent at the current version and rejects future versions.
- A corrupt primary is quarantined and a valid backup loads.
- Two corrupt snapshots recover empty without deleting either invalid file.
- Permission and disk-write failures stay failures.
- Invalid startup config selects defaults only for normal launch.
- Runtime service failure preserves the menu and supports retry.
- Version parsing and comparison reject malformed or regressive releases.
- Redacted logging never emits title, bundle identifier, or user path.
- Termination flushes the newest pending restore request exactly once.

Shell and product gates:

- Strict config check, recovery startup, service-failure rollback, config reload,
  packaged app, install/update rollback, and support-bundle smokes.
- CI compile/test, AddressSanitizer, and ThreadSanitizer on a full Xcode runner.
- Release artifact code-sign verification, notarization/stapling, Gatekeeper
  assessment, architecture inspection, dependency inspection, and checksum.
- Fresh user, permission revoke/regrant, hotkey conflict, corrupt state, sleep/
  wake, login/logout, display hot-plug, fullscreen, and sustained-runtime gates.
- AppKit verification for every new menu/onboarding/recovery visual surface.
- Full Chrome, Firefox, System Settings, Terminal, mixed manual resize, and both
  three-window vertical stack suites using AX and WindowServer frames.

## De-slop constraints

- Extend `RestoreManager`, `Menubar`, and the existing application composition
  root rather than adding generic persistence or UI frameworks.
- Use one small onboarding/recovery window controller only if the menu cannot
  present the required state accessibly.
- Keep release behavior in scripts and workflows, not runtime abstractions.
- Do not add retry loops, update channels, telemetry settings, or compatibility
  modes that are not exercised by the release contract above.
- Delete stale development-only production instructions as the new install path
  becomes authoritative.

## Residual external requirements

An actual public release requires an Apple Developer ID certificate, notarization
credentials, and repository release permissions. CI can validate the unsigned
and ad-hoc paths without those secrets; the release job must refuse to publish
when they are absent.
