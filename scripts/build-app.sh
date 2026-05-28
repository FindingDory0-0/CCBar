#!/bin/bash
# Wrap the ccbar-app SwiftPM binary in a proper macOS .app bundle.
#
# Why: bare `swift run` executables aren't recognized by macOS as GUI apps,
# so NSStatusItem / MenuBarExtra never appears in the menu bar. A minimal
# .app bundle with LSUIElement=YES fixes that and also hides us from the Dock.
#
# Usage:   ./scripts/build-app.sh [--release]
# Output:  build/CCBar.app

set -euo pipefail

CONFIG="debug"
if [[ "${1:-}" == "--release" ]]; then
    CONFIG="release"
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CCBar"
APP_DIR="$PROJECT_ROOT/build/$APP_NAME.app"
EXE_NAME="ccbar"
BUNDLE_ID="com.ccbar.menubar"

# Version can be overridden by release.sh (`CCBAR_VERSION=0.2.0 ./build-app.sh --release`);
# everyday `swift build` runs default to 0.0.0-dev so they're clearly not a release.
APP_VERSION="${CCBAR_VERSION:-0.0.0-dev}"
APP_BUILD="${CCBAR_BUILD:-1}"

# Sparkle feed lives on GitHub Pages of this repo. Single source of truth so
# release.sh can publish here and the running app polls the same URL.
SUFEED_URL="${CCBAR_FEED_URL:-https://findingdory0-0.github.io/CCBar/appcast.xml}"

echo "▸ Building (config=$CONFIG)…"
cd "$PROJECT_ROOT"
swift build -c "$CONFIG" --product ccbar-app

BIN_PATH=".build/$CONFIG/ccbar-app"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "✘ binary not found at $BIN_PATH"
    exit 1
fi

echo "▸ Assembling $APP_DIR …"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$EXE_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$EXE_NAME"

# Embed Sparkle.framework (and any other dynamic frameworks SwiftPM produced).
# The ccbar binary links against @rpath/Sparkle.framework, so the .app must
# carry it under Contents/Frameworks/ to launch outside the .build directory.
FRAMEWORKS_SRC=".build/arm64-apple-macosx/$CONFIG"
EMBEDDED_ANY=0
if [[ -d "$FRAMEWORKS_SRC" ]]; then
    mkdir -p "$APP_DIR/Contents/Frameworks"
    for fw in "$FRAMEWORKS_SRC"/*.framework; do
        [[ -d "$fw" ]] || continue
        echo "  ✓ embed $(basename "$fw")"
        cp -R "$fw" "$APP_DIR/Contents/Frameworks/"
        EMBEDDED_ANY=1
    done
fi

# Tell dyld to look inside our .app's Frameworks/ dir at runtime. SwiftPM
# binaries don't include this rpath by default — without it the @rpath lookup
# for Sparkle.framework fails and the app refuses to launch.
if [[ "$EMBEDDED_ANY" -eq 1 ]]; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/$EXE_NAME" 2>/dev/null || true
fi

# Generate app icon (.icns) from the SF Symbols renderer in scripts/make-icon.swift.
# We render once → scale into a .iconset → run iconutil. About a second of work.
echo "▸ Building app icon …"
ICON_PNG="$PROJECT_ROOT/build/icon-1024.png"
ICONSET="$PROJECT_ROOT/build/AppIcon.iconset"
swift "$PROJECT_ROOT/scripts/make-icon.swift" "$ICON_PNG" || {
    echo "  ⚠️ icon render failed; continuing without custom icon"
}
if [[ -f "$ICON_PNG" ]]; then
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    # macOS expects this exact set of sizes/names in .iconset/.
    for s in 16 32 64 128 256 512 1024; do
        sips -z "$s" "$s" "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    done
    sips -z 32   32   "$ICON_PNG" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
    sips -z 64   64   "$ICON_PNG" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
    sips -z 256  256  "$ICON_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
    sips -z 512  512  "$ICON_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
    sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
    iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
    echo "  ✓ AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>           <string>$EXE_NAME</string>
    <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                 <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>          <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>              <string>$APP_BUILD</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>
    <key>LSUIElement</key>                  <true/>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>

    <!-- Required for NSAppleScript to ask the user for Apple Events permission.
         Without this key macOS silently refuses with -1743 and never prompts. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>CCBar이 iTerm2 / Terminal 등의 창을 활성화하기 위해 자동화 권한이 필요합니다.</string>

    <!-- Required for AXIsProcessTrustedWithOptions to show the permission prompt
         on first use. Without this key the prompt either never appears or is
         worded vaguely. -->
    <key>NSAccessibilityUsageDescription</key>
    <string>CCBar이 다른 Space / 모니터에 있는 창으로 점프하기 위해 손쉬운 사용 권한이 필요합니다.</string>

    <!-- Sparkle auto-update.
         - SUFeedURL: appcast.xml hosted on GitHub Pages of this repo.
         - SUPublicEDKey: EdDSA public key. The matching private key lives in
           the developer's Keychain (created via Sparkle bin/generate_keys);
           release.sh signs each zip with it and writes the signature into the
           appcast. Sparkle 2 REQUIRES this — without it "check for updates"
           silently no-ops.
         - SUEnableAutomaticChecks: true → quiet daily background check. -->
    <key>SUFeedURL</key>
    <string>$SUFEED_URL</string>
    <key>SUPublicEDKey</key>
    <string>12SM1IUFbluC5I2rjT4FaQn7s3gSgfBSPsU7r1aXJJk=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
</dict>
</plist>
PLIST

cat > "$APP_DIR/Contents/PkgInfo" <<EOF
APPL????
EOF

# Ad-hoc codesign with bundle identifier pinned and an explicit
# designated requirement (`-r=`). The requirement is a one-liner; codesign's
# Requirement Language doesn't want a leading `=` here.
#
# Goal: get TCC to key permissions on our bundle id, not the cdhash.
# Default ad-hoc DR includes the cdhash → every rebuild = new TCC entity =
# user has to re-grant Accessibility / Automation. Pinning the DR to
# "identifier com.ccbar.menubar" *should* let new builds inherit grants
# while the bundle id is unchanged (caveat: macOS TCC also looks at cdhash
# stability — Apple's own docs are vague on which wins).
#
# Frameworks must be signed first; --deep handles that. We also force-sign
# the executable to ensure --identifier overrides SwiftPM's auto-generated
# id (`ccbar-app-<hash>`) which is otherwise sticky.
echo "▸ Codesigning (ad-hoc, identifier-pinned requirement) …"
REQ_FILE="$PROJECT_ROOT/build/.codesign-requirement"
cat > "$REQ_FILE" <<REQ
designated => identifier "$BUNDLE_ID"
REQ
codesign --remove-signature "$APP_DIR/Contents/MacOS/$EXE_NAME" 2>/dev/null || true
codesign --force --deep --sign - \
    --identifier "$BUNDLE_ID" \
    --requirements "$REQ_FILE" \
    "$APP_DIR" 2>&1 | sed 's/^/  /'

echo "✓ $APP_DIR"

# --install: copy into /Applications and relaunch from there. Required for
# SMAppService (login item) and Sparkle in-place updates to work — both
# refuse to operate on an app running from a dev/build directory.
if [[ "${CCBAR_INSTALL:-}" == "1" || " $* " == *" --install "* ]]; then
    DEST="/Applications/$APP_NAME.app"
    echo "▸ Installing to $DEST …"
    pkill -x "$EXE_NAME" 2>/dev/null || true
    sleep 1
    rm -rf "$DEST"
    # ditto preserves the code signature + extended attributes.
    ditto "$APP_DIR" "$DEST"
    echo "  ✓ installed"
    echo "▸ Launching from /Applications …"
    open "$DEST"
    echo "✓ running from $DEST"
else
    echo ""
    echo "Launch (dev):       open $APP_DIR"
    echo "Install + run:      CCBAR_INSTALL=1 $0 ${1:-}   (→ /Applications, enables login-item + auto-update)"
    echo "Quit any prior copy:  pkill -f $EXE_NAME"
fi
