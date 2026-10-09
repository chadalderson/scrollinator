#!/usr/bin/env bash
# Builds The Scrollinator (universal: Apple Silicon + Intel).
#
#   ./build.sh            Direct build, for your own Macs and your org. Records MP3 (bundled LAME).
#                         -> build.noindex/direct/The Scrollinator.app and .zip
#   ./build.sh appstore   Mac App Store build: sandboxed, records AAC (.m4a), no LAME.
#                         -> build.noindex/appstore/The Scrollinator.app, plus a signed .pkg for
#                            upload when the App Store certificates and profile are set up.
# The ".noindex" folder keeps Spotlight from listing these copies next to the installed app.
#
# Environment overrides:
#   BUNDLE_ID              bundle identifier           (default: com.chadalderson.scrollinator;
#                          publishing your own copy? use your own, matching your App ID)
#   VERSION                marketing version           (default: 1.0.0)
#   BUILD_NUMBER           build number, must rise with every App Store upload (default: date+time)
#   COPYRIGHT              Info.plist copyright line (default: public domain notice)
#   SIGN_IDENTITY          codesign identity. Direct default: first "Apple Development" certificate
#                          (a stable identity keeps macOS permissions across rebuilds), else ad-hoc;
#                          use "Developer ID Application: ..." for org distribution.
#                          App Store default: "Apple Distribution", else "3rd Party Mac Developer
#                          Application", else "Apple Development" (a sandboxed build to test locally).
#   NOTARY_PROFILE         direct only: notarytool keychain profile; notarizes the zip and staples
#   PROVISIONING_PROFILE   App Store only: path to the Mac App Store .provisionprofile to embed
#   INSTALLER_IDENTITY     App Store only: installer certificate for the .pkg (default: first
#                          "3rd Party Mac Developer Installer" or "Mac Installer Distribution")
#   INSTALL=1              direct only: copy the app to /Applications when done
set -euo pipefail
cd "$(dirname "$0")"

FLAVOR="${1:-direct}"
[[ "$FLAVOR" == direct || "$FLAVOR" == appstore ]] || { echo "usage: $0 [direct|appstore]" >&2; exit 2; }

EXECUTABLE="Scrollinator"
DISPLAY_NAME="The Scrollinator"
BUNDLE_ID="${BUNDLE_ID:-com.chadalderson.scrollinator}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
COPYRIGHT="${COPYRIGHT:-Released into the public domain (The Unlicense)}"
MIN_MACOS="14.0"
OUT="build.noindex/$FLAVOR"
APP="$OUT/$DISPLAY_NAME.app"

first_identity() {   # first valid codesigning/installer identity whose name starts with $1
    security find-identity -v ${2:-} 2>/dev/null | sed -n "s/.*\"\($1[^\"]*\)\".*/\1/p" | head -1
}

if [[ "$FLAVOR" == direct ]]; then
    ENTITLEMENTS="Scrollinator.entitlements"
    SCRATCH=".build"
    : "${SIGN_IDENTITY:=$(first_identity "Apple Development" "-p codesigning")}"
    ./scripts/build-lame.sh
else
    ENTITLEMENTS="Scrollinator-AppStore.entitlements"
    SCRATCH=".build-appstore"
    export SCROLLINATOR_APPSTORE=1
    : "${SIGN_IDENTITY:=$(first_identity "Apple Distribution" "-p codesigning")}"
    : "${SIGN_IDENTITY:=$(first_identity "3rd Party Mac Developer Application" "-p codesigning")}"
    : "${SIGN_IDENTITY:=$(first_identity "Apple Development" "-p codesigning")}"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "==> Compiling $FLAVOR build (arm64 + x86_64)"
bins=()
for arch in arm64 x86_64; do
    triple="$arch-apple-macosx$MIN_MACOS"
    swift build -c release --scratch-path "$SCRATCH" --triple "$triple"
    bins+=("$(swift build -c release --scratch-path "$SCRATCH" --triple "$triple" --show-bin-path)/$EXECUTABLE")
done

echo "==> Assembling $APP"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/$EXECUTABLE" "${bins[@]}"

# Resources/AppIcon.png, when present, replaces the built-in pixel-art icon.
ICON="build.noindex/AppIcon.icns"
ART="Resources/AppIcon.png"
if [[ ! -f "$ICON" || scripts/make-icon.swift -nt "$ICON" || ( -f "$ART" && "$ART" -nt "$ICON" ) ]]; then
    rm -rf "build.noindex/AppIcon.iconset"
    if [[ -f "$ART" ]]; then
        swift scripts/make-icon.swift "build.noindex/AppIcon.iconset" "$ART"
    else
        swift scripts/make-icon.swift "build.noindex/AppIcon.iconset"
    fi
    iconutil -c icns "build.noindex/AppIcon.iconset" -o "$ICON"
    rm -rf "build.noindex/AppIcon.iconset"
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
# The full artwork also shows beside Settings.
[[ -f "$ART" ]] && cp "$ART" "$APP/Contents/Resources/Artwork.png"
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$EXECUTABLE</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>ITSAppUsesNonExemptEncryption</key><false/>
    <key>NSMicrophoneUsageDescription</key>
    <string>The Scrollinator listens to your voice so the script scrolls while you speak and pauses when you stop. Audio stays on your Mac and is saved only if you turn on recording.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>The Scrollinator recognizes the words you say so the script keeps your place as your pace changes. Recognition runs on your Mac; nothing is sent anywhere.</string>
</dict>
</plist>
PLIST

# App Store builds need the provisioning profile embedded and its team and app identifiers
# in the entitlements.
SIGN_ENTITLEMENTS="$ENTITLEMENTS"
if [[ "$FLAVOR" == appstore && -n "${PROVISIONING_PROFILE:-}" ]]; then
    cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
    profile_plist="$(mktemp)"
    security cms -D -i "$PROVISIONING_PROFILE" > "$profile_plist"
    TEAM_ID=$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "$profile_plist")
    rm -f "$profile_plist"
    SIGN_ENTITLEMENTS="$OUT/signing.entitlements"
    cp "$ENTITLEMENTS" "$SIGN_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" "$SIGN_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$SIGN_ENTITLEMENTS"
fi

echo "==> Signing ($SIGN_IDENTITY)"
sign_args=(--force --options runtime --entitlements "$SIGN_ENTITLEMENTS" --sign "$SIGN_IDENTITY")
[[ "$SIGN_IDENTITY" == Developer\ ID* ]] && sign_args+=(--timestamp)
codesign "${sign_args[@]}" "$APP"
codesign --verify --strict "$APP"
rm -f "$OUT/signing.entitlements"

if [[ "$FLAVOR" == direct ]]; then
    ZIP="$OUT/$DISPLAY_NAME.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        echo "==> Notarizing"
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
        rm -f "$ZIP"
        ditto -c -k --keepParent "$APP" "$ZIP"
    fi
    if [[ "${INSTALL:-0}" == "1" ]]; then
        echo "==> Installing to /Applications"
        rm -rf "/Applications/$DISPLAY_NAME.app"
        cp -R "$APP" /Applications/
    fi
    echo "==> Done: $APP  (zip: $ZIP)"
    exit 0
fi

: "${INSTALLER_IDENTITY:=$(first_identity "3rd Party Mac Developer Installer")}"
: "${INSTALLER_IDENTITY:=$(first_identity "Mac Installer Distribution")}"
if [[ -n "${INSTALLER_IDENTITY:-}" && -n "${PROVISIONING_PROFILE:-}" && "$SIGN_IDENTITY" != Apple\ Development* ]]; then
    PKG="$OUT/$DISPLAY_NAME.pkg"
    echo "==> Packaging for the App Store ($INSTALLER_IDENTITY)"
    productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"
    echo "==> Done: $PKG  (upload with Transporter, or: xcrun altool --upload-package)"
else
    echo "==> Done: $APP"
    echo "    Sandboxed build for local testing. For an uploadable .pkg, install the Apple Distribution"
    echo "    and Mac Installer Distribution certificates and set PROVISIONING_PROFILE (see APP_STORE.md)."
fi
