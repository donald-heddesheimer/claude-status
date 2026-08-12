#!/usr/bin/env bash
# Build claude-status as a distributable macOS app.
#
#   ./scripts/build-app.sh              # universal .app, ad-hoc signed
#   ./scripts/build-app.sh --package    # also produce DMG, ZIP and checksums
#   ./scripts/build-app.sh --sparkle    # include the auto-updater
#
# Signing and notarisation are driven entirely by what is present in the
# environment, so the same script runs on a laptop with no Apple account and in
# CI with full credentials:
#
#   DEVELOPER_ID   "Developer ID Application: Name (TEAMID)". Absent -> ad-hoc.
#   AC_API_KEY_ID  App Store Connect key id     ] all three -> notarise
#   AC_API_ISSUER  App Store Connect issuer id  ] and staple
#   AC_API_KEY     path to the .p8 private key  ]
#   SPARKLE_PUBLIC_KEY  EdDSA public key for update verification
#
# An ad-hoc signed app runs fine on the machine that built it, and Gatekeeper
# will refuse it anywhere else. That is the honest default: pretending otherwise
# just moves the discovery to your users.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUILD="$ROOT/build"
APP_NAME="claude-status"
BUNDLE_ID="io.github.donaldheddesheimer.claude-status"
APP="$BUILD/$APP_NAME.app"

PACKAGE=false
USE_SPARKLE=false
for argument in "$@"; do
  case "$argument" in
    --package) PACKAGE=true ;;
    --sparkle) USE_SPARKLE=true ;;
    # Reads the header block itself rather than a line range, which drifts the
    # moment anyone edits the comment.
    --help|-h) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' \
                 "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $argument" >&2; exit 2 ;;
  esac
done

VERSION="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
  "$ROOT/.claude-plugin/plugin.json")"
# Monotonic build number: Sparkle and macOS both compare CFBundleVersion, and a
# version string alone cannot express "same version, rebuilt".
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }

# ------------------------------------------------------------------ compile

say "Building $APP_NAME $VERSION (build $BUILD_NUMBER)"
rm -rf "$BUILD"
mkdir -p "$BUILD"

# Always a non-empty array: macOS ships bash 3.2, where expanding an empty one
# under `set -u` is an error rather than the no-op every other shell gives you.
SWIFT_ENV=(env)
if [ "$USE_SPARKLE" = true ]; then
  SWIFT_ENV+=(CLAUDE_STATUS_SPARKLE=1)
  say "Sparkle enabled"
fi

# Universal, so one download works on Apple silicon and Intel alike.
"${SWIFT_ENV[@]}" swift build \
  --package-path "$ROOT/mac-app" \
  -c release \
  --arch arm64 --arch x86_64

BINARY="$(
  "${SWIFT_ENV[@]}" swift build --package-path "$ROOT/mac-app" -c release \
    --arch arm64 --arch x86_64 --show-bin-path
)/StatusPet"

[ -x "$BINARY" ] || { echo "build produced no binary at $BINARY" >&2; exit 1; }

# ----------------------------------------------------------------- assemble

say "Assembling bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

# The icon is rendered from the same pixel map the pet is drawn from, so it can
# never drift from the critter on screen.
say "Rendering icon"
ICONSET="$BUILD/icon.iconset"
"$BINARY" --export-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

SPARKLE_KEYS=""
if [ "$USE_SPARKLE" = true ]; then
  # Without a public key Sparkle refuses to install anything, which is the
  # correct failure: an unverified update channel is worse than none.
  SPARKLE_KEYS="
    <key>SUFeedURL</key>
    <string>https://github.com/donald-heddesheimer/claude-status/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>${SPARKLE_PUBLIC_KEY:-}</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>claude-status</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- Accessory app: lives in the corner of the screen, not in the Dock. -->
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT licensed</string>$SPARKLE_KEYS
</dict>
</plist>
PLIST

if [ "$USE_SPARKLE" = true ]; then
  FRAMEWORK="$(find "$ROOT/mac-app/.build" -name 'Sparkle.framework' -type d 2>/dev/null | head -n 1)"
  if [ -z "$FRAMEWORK" ]; then
    echo "--sparkle was requested but Sparkle.framework is not in the build output" >&2
    exit 1
  fi
  say "Embedding $(basename "$FRAMEWORK")"
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$FRAMEWORK" "$APP/Contents/Frameworks/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi

# --------------------------------------------------------------------- sign

if [ -n "${DEVELOPER_ID:-}" ]; then
  say "Signing as $DEVELOPER_ID"
  # Frameworks first: a bundle must be signed inside out.
  if [ -d "$APP/Contents/Frameworks" ]; then
    find "$APP/Contents/Frameworks" -maxdepth 1 -name '*.framework' -print0 \
      | xargs -0 -I {} codesign --force --timestamp --options runtime \
          --sign "$DEVELOPER_ID" {}
  fi
  # Hardened runtime is a precondition for notarisation.
  codesign --force --timestamp --options runtime \
    --sign "$DEVELOPER_ID" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  say "No DEVELOPER_ID set — ad-hoc signing"
  echo "    This app will run here and be refused by Gatekeeper elsewhere."
  codesign --force --deep --sign - "$APP"
fi

# ---------------------------------------------------------------- notarise

notarize() {
  local target="$1"
  if [ -z "${AC_API_KEY_ID:-}" ] || [ -z "${AC_API_ISSUER:-}" ] || [ -z "${AC_API_KEY:-}" ]; then
    say "No App Store Connect credentials — skipping notarisation"
    return 0
  fi
  say "Notarising $(basename "$target")"
  xcrun notarytool submit "$target" \
    --key "$AC_API_KEY" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER" \
    --wait --timeout 30m
  # Stapling lets the app launch on a machine that is offline the first time.
  xcrun stapler staple "$target"
}

# ----------------------------------------------------------------- package

if [ "$PACKAGE" = true ]; then
  say "Packaging"
  ZIP="$BUILD/$APP_NAME-$VERSION.zip"
  # ditto, not zip: it is the only one that preserves the signature.
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"

  DMG="$BUILD/$APP_NAME-$VERSION.dmg"
  STAGE="$BUILD/dmg"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
  rm -rf "$STAGE"

  if [ -n "${DEVELOPER_ID:-}" ]; then
    codesign --force --sign "$DEVELOPER_ID" "$DMG"
    notarize "$DMG"
  fi

  # Checksums so a download can be verified independently of the transport,
  # and so install.sh can refuse a corrupted or substituted archive.
  ( cd "$BUILD" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS )

  say "Artifacts"
  printf '    %s\n' "$(basename "$ZIP")" "$(basename "$DMG")" "SHA256SUMS"
  sed 's/^/    /' "$BUILD/SHA256SUMS"
else
  say "Built $APP"
fi

# A signature that does not verify is worth knowing about before shipping.
say "Signature"
codesign -dv --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
spctl --assess --type execute --verbose "$APP" 2>&1 | sed 's/^/    /' || \
  echo "    (Gatekeeper rejects it — expected without a Developer ID)"
