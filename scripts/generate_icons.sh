#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
assets_dir="$repo_root/Packaging/Assets"
iconset="$assets_dir/NarwhalIcon.iconset"
app_svg="$assets_dir/NarwhalAppIcon.svg"
toolbar_svg="$assets_dir/NarwhalToolbarIcon.svg"

command -v magick >/dev/null 2>&1 || {
  echo "ImageMagick is required to render SVG icons. Install it with: brew install imagemagick" >&2
  exit 1
}
command -v iconutil >/dev/null 2>&1 || {
  echo "iconutil is required to inspect macOS app icons." >&2
  exit 1
}

rm -rf "$iconset"
mkdir -p "$iconset"

render_png() {
  local size="$1"
  local output="$2"
  magick -background none "$app_svg" \
    -resize "${size}x${size}" \
    -alpha on \
    -type TrueColorAlpha \
    -define png:color-type=6 \
    "PNG32:$output"
}

render_png 16 "$iconset/icon_16x16.png"
render_png 32 "$iconset/icon_16x16@2x.png"
render_png 32 "$iconset/icon_32x32.png"
render_png 64 "$iconset/icon_32x32@2x.png"
render_png 128 "$iconset/icon_128x128.png"
render_png 256 "$iconset/icon_128x128@2x.png"
render_png 256 "$iconset/icon_256x256.png"
render_png 512 "$iconset/icon_256x256@2x.png"
render_png 512 "$iconset/icon_512x512.png"
render_png 1024 "$iconset/icon_512x512@2x.png"

python3 - "$assets_dir/NarwhalIcon.icns" \
  icp4 "$iconset/icon_16x16.png" \
  icp5 "$iconset/icon_32x32.png" \
  icp6 "$iconset/icon_32x32@2x.png" \
  ic07 "$iconset/icon_128x128.png" \
  ic08 "$iconset/icon_256x256.png" \
  ic09 "$iconset/icon_512x512.png" \
  ic10 "$iconset/icon_512x512@2x.png" <<'PY'
import struct
import sys

out_path = sys.argv[1]
pairs = sys.argv[2:]
if len(pairs) % 2 != 0:
    raise SystemExit("icns chunk arguments must be type/path pairs")

chunks = []
for chunk_type, path in zip(pairs[0::2], pairs[1::2]):
    if len(chunk_type) != 4:
        raise SystemExit(f"invalid icns chunk type: {chunk_type}")
    with open(path, "rb") as handle:
        data = handle.read()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise SystemExit(f"{path} is not a PNG")
    chunks.append(chunk_type.encode("ascii") + struct.pack(">I", len(data) + 8) + data)

payload = b"".join(chunks)
with open(out_path, "wb") as handle:
    handle.write(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
PY

magick -background none "$toolbar_svg" \
  -resize 18x18 \
  -alpha on \
  -type TrueColorAlpha \
  -define png:color-type=6 \
  "PNG32:$assets_dir/NarwhalToolbarIcon.png"
magick -background none "$toolbar_svg" \
  -resize 36x36 \
  -alpha on \
  -type TrueColorAlpha \
  -define png:color-type=6 \
  "PNG32:$assets_dir/NarwhalToolbarIcon@2x.png"

echo "Generated $assets_dir/NarwhalIcon.icns"
echo "Generated $assets_dir/NarwhalToolbarIcon.png"
echo "Generated $assets_dir/NarwhalToolbarIcon@2x.png"
