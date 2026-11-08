#!/bin/bash
# Bygger FediMactastic.app (krever bare Command Line Tools, ikke hele Xcode).
#   ./build-app.sh              release-bygg → FediMactastic.app
#   CONFIG=debug ./build-app.sh
#   ./build-app.sh --install    bygger og kopierer appen til ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/FediMactastic"

APP="FediMactastic.app"
echo "==> Setter sammen $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FediMactastic"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns Support/bakgrunn.jpg "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc-signering så appen kan startes fra Finder
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "(signering hoppet over)"

echo "==> Ferdig: $(pwd)/$APP"

if [ "${1:-}" = "--install" ]; then
    # ~/Applications krever ikke administratorrettigheter, og appen vises likevel i Launchpad og Spotlight
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    rm -rf "$DEST/$APP"
    cp -R "$APP" "$DEST/"
    echo "==> Installert i $DEST/$APP"
fi
