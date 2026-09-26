#!/usr/bin/env bash
# Local DMG by default. A public binary release requires Developer ID + notarization.
set -euo pipefail

VERSION="${VERSION:-0.1.0}"
ARCH="${ARCH:-arm64}"
NOTARIZE="${NOTARIZE:-0}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${PROJECT_DIR}/build}"
APP_NAME=KeepAwakeMac

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'VERSION must be x.y.z' >&2; exit 1; }
[[ "$ARCH" == arm64 || "$ARCH" == universal ]] || { echo 'ARCH must be arm64 or universal' >&2; exit 1; }
[[ "$NOTARIZE" == 0 || "$NOTARIZE" == 1 ]] || { echo 'NOTARIZE must be 0 or 1' >&2; exit 1; }
if [[ "$NOTARIZE" == 1 && ( -z "$SIGN_IDENTITY" || -z "${KEYCHAIN_PROFILE:-}" ) ]]; then
  echo 'Notarization requires SIGN_IDENTITY and KEYCHAIN_PROFILE.' >&2
  exit 1
fi

(cd "$PROJECT_DIR" && xcodegen generate)
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
STAGING="$(mktemp -d "$BUILD_DIR/dmg-staging.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

SIGNING="${SIGN_IDENTITY:--}"
HARDENED=NO
[[ -z "$SIGN_IDENTITY" ]] || HARDENED=YES
ARCHS="$ARCH"
[[ "$ARCH" != universal ]] || ARCHS='arm64 x86_64'
xcodebuild -project "$PROJECT_DIR/$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
  -configuration Release -derivedDataPath "$BUILD_DIR/DerivedData" \
  ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO MARKETING_VERSION="$VERSION" \
  CODE_SIGN_IDENTITY="$SIGNING" ENABLE_HARDENED_RUNTIME="$HARDENED" build

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/$APP_NAME.app"
codesign --verify --deep --strict "$APP_PATH"
ditto "$APP_PATH" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION-$ARCH.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi
if [[ "$NOTARIZE" == 1 ]]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi
shasum -a 256 "$DMG_PATH" | awk '{print $1}' > "$DMG_PATH.sha256"
echo "Built: $DMG_PATH"
if [[ "$NOTARIZE" != 1 ]]; then
  echo 'Local test build only; do not publish this as a signed, notarized release.'
fi
