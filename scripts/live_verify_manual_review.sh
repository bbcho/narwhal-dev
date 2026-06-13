#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

cd "$repo_root"
export NARWHAL_LIVE_VERIFIER_REVIEW=1
export NARWHAL_LIVE_VERIFIER_REVIEW_DELAY="${NARWHAL_LIVE_VERIFIER_REVIEW_DELAY:-1.5}"
export NARWHAL_VISUAL_ARTIFACT_DIR="${NARWHAL_VISUAL_ARTIFACT_DIR:-/private/tmp/narwhal-live-artifacts}"

echo "Manual live verifier review enabled."
echo "Each verified moved-window placement pauses for ${NARWHAL_LIVE_VERIFIER_REVIEW_DELAY}s."
echo "Visual artifacts: $NARWHAL_VISUAL_ARTIFACT_DIR"

"$script_dir/live_verify_all.sh"
