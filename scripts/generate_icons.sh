#!/usr/bin/env bash
set -euo pipefail

# Regenerates Narwhal's app and menubar icons from Packaging/Assets/AppIconSource.png.
#
# Source: AppIconSource.png must be a 1024x1024 RGBA PNG with transparency.
# Outputs:
#   - NarwhalIcon.icns           (Dock / Finder / Applications)
#   - NarwhalIcon.iconset/       (intermediate per-size PNGs)
#   - NarwhalToolbarIcon.png     (menubar @1x, 18x18, black silhouette template)
#   - NarwhalToolbarIcon@2x.png  (menubar @2x, 36x36, black silhouette template)
#
# The menubar icons are extracted as alpha silhouettes; macOS tints them based on
# menu bar theme. For a hand-tuned menubar glyph, replace these PNGs directly.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
assets_dir="$repo_root/Packaging/Assets"
source_png="$assets_dir/AppIconSource.png"
iconset="$assets_dir/NarwhalIcon.iconset"

command -v magick >/dev/null 2>&1 || {
  echo "ImageMagick is required. Install: brew install imagemagick" >&2
  exit 1
}
command -v iconutil >/dev/null 2>&1 || {
  echo "iconutil is required (ships with Xcode Command Line Tools)." >&2
  exit 1
}

if [ ! -f "$source_png" ]; then
  echo "missing $source_png" >&2
  echo "Drop a 1024x1024 RGBA PNG at that path and rerun." >&2
  exit 1
fi

rm -rf "$iconset"
mkdir -p "$iconset"

render_app() {
  local size="$1" output="$2"
  magick "$source_png" -resize "${size}x${size}" \
    -alpha on -type TrueColorAlpha -define png:color-type=6 "PNG32:$output"
}

render_app 16   "$iconset/icon_16x16.png"
render_app 32   "$iconset/icon_16x16@2x.png"
render_app 32   "$iconset/icon_32x32.png"
render_app 64   "$iconset/icon_32x32@2x.png"
render_app 128  "$iconset/icon_128x128.png"
render_app 256  "$iconset/icon_128x128@2x.png"
render_app 256  "$iconset/icon_256x256.png"
render_app 512  "$iconset/icon_256x256@2x.png"
render_app 512  "$iconset/icon_512x512.png"
render_app 1024 "$iconset/icon_512x512@2x.png"

iconutil -c icns "$iconset" -o "$assets_dir/NarwhalIcon.icns"

# Menubar icons. Generates black silhouette (NarwhalToolbarIcon{,@2x}.png) for
# light menu bars and an inverted white silhouette (NarwhalToolbarIconDark{,@2x}.png)
# for dark menu bars. Menubar.swift swaps based on effectiveAppearance because
# isTemplate on NSImage(contentsOf:)-loaded PNGs is unreliable.
toolbar_source="$assets_dir/ToolbarIconSource.png"
if [ ! -f "$toolbar_source" ]; then
  echo "missing $toolbar_source (black-on-transparent narwhal source)" >&2
  exit 1
fi

# Black silhouette → light-mode menubar.
magick "$toolbar_source" -resize 36x36 \
  -define png:color-type=6 "PNG32:$assets_dir/NarwhalToolbarIcon@2x.png"
magick "$toolbar_source" -resize 18x18 \
  -define png:color-type=6 "PNG32:$assets_dir/NarwhalToolbarIcon.png"

# White silhouette → dark-mode menubar. Invert RGB only; preserve alpha.
magick "$toolbar_source" -channel RGB -negate +channel -resize 36x36 \
  -define png:color-type=6 "PNG32:$assets_dir/NarwhalToolbarIconDark@2x.png"
magick "$toolbar_source" -channel RGB -negate +channel -resize 18x18 \
  -define png:color-type=6 "PNG32:$assets_dir/NarwhalToolbarIconDark.png"

echo "Generated $assets_dir/NarwhalIcon.icns"
echo "Generated $assets_dir/NarwhalToolbarIcon.png"
echo "Generated $assets_dir/NarwhalToolbarIcon@2x.png"
