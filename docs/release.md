# Release Process

Narwhal releases are produced only from an exact semantic version tag and a
clean repository. The pipeline builds one arm64 artifact, embeds the Lua runtime
and license notice, signs nested code and the app with Developer ID, notarizes,
staples, runs Gatekeeper assessment, and records checksums.

## Required GitHub Secrets

The release workflow expects:

- `CERTIFICATE_P12_BASE64`: Developer ID Application certificate and private key.
- `CERTIFICATE_PASSWORD`: password for that PKCS#12 file.
- `KEYCHAIN_PASSWORD`: temporary CI keychain password.
- `DEVELOPER_ID_APPLICATION`: full codesign identity name.
- `NOTARY_KEY_BASE64`: App Store Connect API private key.
- `NOTARY_KEY_ID`: API key identifier.
- `NOTARY_ISSUER_ID`: API issuer identifier.

The workflow also needs permission to create a GitHub release. Secrets must be
configured before a release tag is pushed; the script intentionally has no
ad-hoc or unsigned fallback.

## Local Release Candidate

Create a stable notarytool keychain profile, then run from a clean commit that
already has the exact tag:

```sh
export NARWHAL_SIGNING_IDENTITY='Developer ID Application: Example (TEAMID)'
export NARWHAL_NOTARY_PROFILE='narwhal-release'

scripts/release.sh \
  --version 1.2.3 \
  --build-number 123 \
  --output .build/releases/1.2.3-123
```

`scripts/release.sh` refuses a dirty tree, a noncanonical version/build, a tag
other than `vVERSION` at `HEAD`, an unsafe/reused output directory, a missing
Developer ID identity, or missing notary credentials.

## Artifacts

Successful output contains:

- `Narwhal-VERSION-arm64.zip`: notarized and stapled application archive.
- `Narwhal-VERSION-arm64.dSYM.zip`: matching debug symbols.
- `release.json`: version, build, commit, architecture, and Lua checksum.
- `SHA256SUMS`: checksums for all published assets.

Keep dSYMs for every published build. Verify the application ZIP after
extraction with `scripts/verify_app_bundle.sh --gatekeeper` and verify
`SHA256SUMS` before publishing.

## GitHub Release

Pushing `vMAJOR.MINOR.PATCH` invokes `.github/workflows/release.yml`. It imports
the certificate into a temporary keychain, configures notarytool, runs the
release script, and creates a GitHub release with generated notes.

The in-app update checker ignores drafts and prereleases. It becomes useful only
after the first stable GitHub release exists; before that, the latest-release
endpoint legitimately reports no release.

Follow the full [production gate matrix](sprint-gates.md) before tagging.
