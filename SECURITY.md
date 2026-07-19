# Security Policy

## Supported Versions

Narwhal is pre-1.0. Security fixes are applied to the latest published release
and the default branch; older builds are not maintained.

## Reporting a Vulnerability

Do not open a public issue for a suspected vulnerability or attach logs, restore
state, config, or support bundles to one. Use this repository's private GitHub
Security Advisory reporting flow and include:

- affected Narwhal version and build;
- macOS version and hardware architecture;
- reproduction steps and impact;
- whether Accessibility, IPC, restore, config, update, installer, or packaging
  behavior is involved;
- a minimal redacted attachment only when necessary.

You should receive an acknowledgement within seven days. Remediation and
disclosure timing depend on severity and whether an Apple platform behavior is
involved.

For non-security bugs, use a normal GitHub issue and prefer the privacy-safe
diagnostics or reviewed support bundle described in [docs/privacy.md](docs/privacy.md).
