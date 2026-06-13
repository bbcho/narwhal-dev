#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

cd "$repo_root"
export NARWHAL_VISUAL_ARTIFACT_DIR="${NARWHAL_VISUAL_ARTIFACT_DIR:-/private/tmp/narwhal-live-artifacts}"

"$script_dir/live_verify_all.sh"
"$script_dir/smoke_packaged_app.sh"

echo "live_verify_next_level passed"
echo "Visual artifacts: $NARWHAL_VISUAL_ARTIFACT_DIR"
