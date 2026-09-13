#!/bin/bash
# Builds Reopen.app from the SwiftPM package.
#
#   ./build.sh          release build + .app bundle
#   ./build.sh --run    build, then (re)launch the app
set -euo pipefail

cd "$(dirname "$0")"

RUN=0
for arg in "$@"; do
    case "$arg" in
        --run) RUN=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

APP="build/Reopen.app"

echo "▸ Compiling…"
swift build --configuration release --disable-sandbox
BIN="$(swift build --configuration release --disable-sandbox --show-bin-path)/Reopen"

echo "▸ Bundling ${APP}…"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS"
cp "$BIN" "${APP}/Contents/MacOS/Reopen"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
if [[ ! -f Resources/AppIcon.icns ]]; then
    ./Tools/make-icon.sh >/dev/null
fi
mkdir -p "${APP}/Contents/Resources"
cp Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"

# Ad-hoc by default: every rebuild changes the signature, so macOS forgets the Accessibility grant.
# Set SIGN_IDENTITY to a local code signing certificate to keep the grant across rebuilds.
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

echo "✓ ${APP}"

if [[ $RUN -eq 1 ]]; then
    pkill -x Reopen 2>/dev/null || true
    open "$APP"
fi
