#!/bin/bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export USER="$(id -un)" LOGNAME="$(id -un)"
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen" >&2; exit 1; }
SDK="$(xcrun --sdk iphoneos --show-sdk-version)"
xcodegen generate --spec project.yml
xcodebuild -project PKAtlas.xcodeproj -scheme PKAtlas -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath "$PWD/.build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM='' clean build
APP="$PWD/.build/DerivedData/Build/Products/Release-iphoneos/PKAtlas.app"
test -s "$APP/PKAtlas"
# Strip nonessential symbols: Swift/Xcode otherwise embeds the builder's
# absolute home directory in Mach-O symbol strings, even for Release builds.
xcrun strip -Sx "$APP/PKAtlas"
python3 Scripts/audit-release.py "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")"
ICLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Downloads"
OUT_DIR="${PKATLAS_IPA_OUTPUT_DIR:-$ICLOUD}"
if [[ ! -d "$OUT_DIR" ]]; then OUT_DIR="$PWD/dist"; fi
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/PKAtlas-iOS${SDK}-v${VERSION}-build${BUILD}-unsigned.ipa"
if [[ -e "$OUT" ]]; then OUT="$OUT_DIR/PKAtlas-iOS${SDK}-v${VERSION}-build${BUILD}-$(date +%Y%m%d-%H%M%S)-unsigned.ipa"; fi
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Payload"
ditto "$APP" "$STAGING/Payload/PKAtlas.app"
(cd "$STAGING" && zip -qry "$OUT" Payload)
unzip -tq "$OUT" >/dev/null
shasum -a 256 "$OUT"
echo "Unsigned IPA: $OUT"
