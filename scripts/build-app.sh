#!/bin/bash
# Builds "English Subtitles Generator, Cut & Join Videos.app" (Intel, macOS 12+) and zips it into dist/.
#
#   FFMPEG_BIN=/path/to/ffmpeg scripts/build-app.sh
#
# FFMPEG_BIN, FFPROBE_BIN: static ffmpeg and ffprobe to bundle (required unless SKIP_FFMPEG=1).
# ARCH: x86_64 (default) or arm64.
# VERSION: shown in Finder's Get Info (default 1.0.0).
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${ARCH:-x86_64}"
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD_NUMBER:-1}"
APP_NAME="English Subtitles Generator, Cut & Join Videos"
APP="dist/$APP_NAME.app"

# Prints the minimum macOS version a Mach-O binary declares.
min_macos() {
  otool -l "$1" | awk '
    /LC_BUILD_VERSION/ {b=1} b && /minos/ {print $2; exit}
    /LC_VERSION_MIN_MACOSX/ {v=1} v && /version/ {print $2; exit}'
}

# Fails if the binary needs a newer macOS than 12.
require_monterey() {
  local minos
  minos="$(min_macos "$1")"
  echo "$(basename "$1"): minimum macOS ${minos:-unknown}"
  if [ -n "$minos" ] && [ "${minos%%.*}" -gt 12 ]; then
    echo "error: $1 requires macOS $minos, but the target Mac runs macOS 12" >&2
    exit 1
  fi
}

swift build -c release --arch "$ARCH"
BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/EnglishSubtitleMaker" "$APP/Contents/MacOS/EnglishSubtitleMaker"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Packaging/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
require_monterey "$APP/Contents/MacOS/EnglishSubtitleMaker"

cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

if [ -f Packaging/AppIcon.icns ]; then
  cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

if [ "${SKIP_FFMPEG:-0}" != "1" ]; then
  : "${FFMPEG_BIN:?set FFMPEG_BIN to a static ffmpeg binary}"
  cp "$FFMPEG_BIN" "$APP/Contents/Resources/ffmpeg"
  chmod 755 "$APP/Contents/Resources/ffmpeg"
  require_monterey "$APP/Contents/Resources/ffmpeg"
  lipo -archs "$APP/Contents/Resources/ffmpeg"
  : "${FFPROBE_BIN:?set FFPROBE_BIN to a static ffprobe binary}"
  cp "$FFPROBE_BIN" "$APP/Contents/Resources/ffprobe"
  chmod 755 "$APP/Contents/Resources/ffprobe"
  require_monterey "$APP/Contents/Resources/ffprobe"
fi

# Ad-hoc signature: not notarised, but lets macOS run the bundle after the
# quarantine flag is removed (see README).
codesign --force --sign - "$APP/Contents/Resources/ffmpeg" 2>/dev/null || true
codesign --force --sign - "$APP/Contents/Resources/ffprobe" 2>/dev/null || true
codesign --force --sign - "$APP"
codesign --verify --verbose "$APP"

(cd dist && ditto -c -k --keepParent "$APP_NAME.app" "EnglishSubtitlesGenerator-CutJoinVideos-macOS.zip")
echo "Built dist/EnglishSubtitlesGenerator-CutJoinVideos-macOS.zip"
