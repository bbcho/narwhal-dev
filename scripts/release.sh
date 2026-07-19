#!/usr/bin/env bash
set -euo pipefail

version=""
build_number=""
output_root=""
replace_existing="false"

usage() {
  cat <<'USAGE'
usage: scripts/release.sh --version MAJOR.MINOR.PATCH --build-number INTEGER [options]

Builds, Developer ID signs, notarizes, staples, and verifies an arm64 release.
Requires NARWHAL_SIGNING_IDENTITY and NARWHAL_NOTARY_PROFILE.

Options:
  --output DIR   Release output. Default: .build/releases/VERSION-BUILD.
  --replace      Replace that exact release output directory.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || { echo "--version requires MAJOR.MINOR.PATCH" >&2; exit 2; }
      version="$2"
      shift 2
      ;;
    --build-number)
      [ "$#" -ge 2 ] || { echo "--build-number requires an integer" >&2; exit 2; }
      build_number="$2"
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || { echo "--output requires a directory" >&2; exit 2; }
      output_root="$2"
      shift 2
      ;;
    --replace)
      replace_existing="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo "--version must be a canonical MAJOR.MINOR.PATCH value" >&2
  exit 2
}
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || {
  echo "--build-number must be a positive integer" >&2
  exit 2
}

signing_identity="${NARWHAL_SIGNING_IDENTITY:-}"
notary_profile="${NARWHAL_NOTARY_PROFILE:-}"
[[ "$signing_identity" == "Developer ID Application: "* ]] || {
  echo "NARWHAL_SIGNING_IDENTITY must name a Developer ID Application certificate" >&2
  exit 1
}
[ -n "$notary_profile" ] || {
  echo "NARWHAL_NOTARY_PROFILE must name a notarytool keychain profile" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

git diff --quiet && git diff --cached --quiet || {
  echo "release requires a clean worktree and index" >&2
  exit 1
}
git tag --points-at HEAD | grep -Fxq "v$version" || {
  echo "HEAD must have the exact release tag v$version" >&2
  exit 1
}

if [ -z "$output_root" ]; then
  output_root="$repo_root/.build/releases/$version-$build_number"
elif [[ "$output_root" != /* ]]; then
  output_root="$repo_root/$output_root"
fi
case "$output_root" in
  ""|/|"$repo_root")
    echo "refusing unsafe release output: $output_root" >&2
    exit 2
    ;;
esac
if [ -e "$output_root" ]; then
  [ "$replace_existing" = "true" ] || {
    echo "release output exists; rerun with --replace: $output_root" >&2
    exit 1
  }
  rm -rf "$output_root"
fi
mkdir -p "$output_root"

package_root="$output_root/package"
NARWHAL_SIGNING_IDENTITY="$signing_identity" \
  "$repo_root/scripts/build_app_bundle.sh" \
  --configuration release \
  --output "$package_root" \
  --version "$version" \
  --build-number "$build_number" \
  --architecture arm64 \
  --replace

app_path="$package_root/Narwhal.app"
dsym_path="$output_root/Narwhal.app.dSYM"
app_zip="$output_root/Narwhal-$version-arm64.zip"
dsym_zip="$output_root/Narwhal-$version-arm64.dSYM.zip"

dsymutil "$app_path/Contents/MacOS/NarwhalApp" -o "$dsym_path"
ditto -c -k --keepParent "$app_path" "$app_zip"
xcrun notarytool submit "$app_zip" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"

rm -f "$app_zip"
ditto -c -k --keepParent "$app_path" "$app_zip"
ditto -c -k --keepParent "$dsym_path" "$dsym_zip"

"$repo_root/scripts/verify_app_bundle.sh" \
  --app "$app_path" \
  --version "$version" \
  --build-number "$build_number" \
  --architecture arm64 \
  --gatekeeper

commit="$(git rev-parse HEAD)"
lua_sha="$(shasum -a 256 "$app_path/Contents/Frameworks/liblua.dylib" | awk '{ print $1 }')"
printf '{\n  "version": "%s",\n  "build": "%s",\n  "commit": "%s",\n  "architecture": "arm64",\n  "minimumMacOS": "26.0",\n  "luaSHA256": "%s"\n}\n' \
  "$version" "$build_number" "$commit" "$lua_sha" > "$output_root/release.json"

(
  cd "$output_root"
  shasum -a 256 \
    "$(basename "$app_zip")" \
    "$(basename "$dsym_zip")" \
    release.json > SHA256SUMS
)

echo "Release artifacts ready in $output_root"
