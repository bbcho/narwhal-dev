# Privacy

Narwhal is a local window manager. It has no analytics, advertising SDK,
automatic telemetry, remote logging, or automatic crash upload.

## Local Data

Narwhal uses Accessibility to inspect and manipulate windows. Its restore state
may contain window bundle identifiers, titles, roles, frames, occurrence
indices, and display/workspace mappings. That state stays under
`~/Library/Application Support/narwhal` with owner-only permissions. A previous
valid snapshot is retained for recovery, and invalid snapshots are quarantined
locally with the same permissions.

The Lua config stays under `~/.config/narwhal`. It is never included in a support
bundle.

## Logs and Diagnostics

Window titles, bundle identifiers, and absolute paths are redacted before a
message reaches unified logging, stderr, or the file log. Logs rotate locally at
5 MiB with three retained generations.

Runtime diagnostics contain version/build, Accessibility and observer status,
aggregate display/window counts, transient numeric window/Space identifiers,
queue depths, dropped-log count, the last command name, and bounded latency
summaries. They do not contain config contents, restore records, window titles,
bundle identifiers, or file paths.

**Export Support Bundle…** creates a local ZIP containing only diagnostics JSON
and up to 4 MiB of redacted logs. Export is explicit; Narwhal does not transmit
the file. Review it before sharing because free-form error text can still reveal
unexpected context despite the redaction rules.

## Network Access

Narwhal makes a network request only when the user selects **Check for
Updates…**. It requests the latest stable release metadata from GitHub for
`bbcho/narwhal-dev`, with a 10-second timeout and a 1 MiB response limit. It
accepts only an HTTPS GitHub release page. It does not send window, config,
restore, diagnostic, or log data and does not download or run an update.

## Removing Data

Run `scripts/uninstall_local.sh` to remove the app and login-item registration.
Remove the config, restore, and log directories separately if you also want to
delete local user data; uninstall deliberately leaves those files available for
reinstallation and support investigation.
