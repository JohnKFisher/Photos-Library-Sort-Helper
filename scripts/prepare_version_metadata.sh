#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

MARKETING_VERSION="$(cat VERSION)"
BUILD_NUMBER="$(cat BUILD_NUMBER)"
if ! [[ "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must use MAJOR.MINOR.PATCH; got: $MARKETING_VERSION" >&2
    exit 1
fi
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "BUILD_NUMBER must be numeric; got: $BUILD_NUMBER" >&2
    exit 1
fi

IOS_VERSION_FILE="$ROOT_DIR/iOSApp/BuildVersion.xcconfig"
IOS_VERSION_TMP="$(mktemp "$ROOT_DIR/iOSApp/BuildVersion.XXXXXX")"
BUILD_INFO_DIR="$ROOT_DIR/.build"
BUILD_INFO_FILE="$BUILD_INFO_DIR/BuildInfo.plist"
BUILD_INFO_TMP="$(mktemp "${TMPDIR:-/tmp}/photosort-build-info.XXXXXX.plist")"
cleanup() {
    rm -f "$IOS_VERSION_TMP" "$BUILD_INFO_TMP"
}
trap cleanup EXIT

cat > "$IOS_VERSION_TMP" <<EOF
MARKETING_VERSION = $MARKETING_VERSION
CURRENT_PROJECT_VERSION = $BUILD_NUMBER
EOF
mv "$IOS_VERSION_TMP" "$IOS_VERSION_FILE"

INFO_PLIST_PATH="${INFO_PLIST_PATH:-$ROOT_DIR/Resources/Info.plist}"
mkdir -p "$BUILD_INFO_DIR"
cp "$INFO_PLIST_PATH" "$BUILD_INFO_TMP"
if /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILD_INFO_TMP" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$BUILD_INFO_TMP"
else
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $MARKETING_VERSION" "$BUILD_INFO_TMP"
fi
if /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILD_INFO_TMP" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$BUILD_INFO_TMP"
else
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$BUILD_INFO_TMP"
fi
mv "$BUILD_INFO_TMP" "$BUILD_INFO_FILE"
echo "Prepared derived Mac/iOS metadata for $MARKETING_VERSION ($BUILD_NUMBER)."
