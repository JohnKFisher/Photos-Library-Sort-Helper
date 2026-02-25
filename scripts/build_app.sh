#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Photo Sort Helper.app"
APP_DIR="$ROOT_DIR/dist/$APP_NAME"
INFO_PLIST_PATH="$ROOT_DIR/Resources/Info.plist"
VERSION_STATE_DIR="$ROOT_DIR/.build"
VERSION_STATE_FILE="$VERSION_STATE_DIR/version-build-state"

current_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST_PATH")"
current_source_hash="$(
    {
        find "$ROOT_DIR/Sources" -type f
        find "$ROOT_DIR/Resources" -type f ! -name 'Info.plist'
        echo "$ROOT_DIR/Package.swift"
        echo "$ROOT_DIR/scripts/build_app.sh"
    } | LC_ALL=C sort | while IFS= read -r file_path; do
        shasum "$file_path"
    done | shasum | awk '{print $1}'
)"

last_version=""
last_build="0"
last_hash=""
if [[ -f "$VERSION_STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$VERSION_STATE_FILE"
    last_version="${VERSION:-}"
    last_build="${BUILD:-0}"
    last_hash="${SOURCE_HASH:-}"
fi

if [[ "$current_version" == "$last_version" && "$last_build" =~ ^[0-9]+$ ]]; then
    if [[ "$current_source_hash" == "$last_hash" ]]; then
        next_build="$last_build"
    else
        next_build="$((last_build + 1))"
    fi
else
    next_build="1"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $next_build" "$INFO_PLIST_PATH"
mkdir -p "$VERSION_STATE_DIR"
cat >"$VERSION_STATE_FILE" <<EOF
VERSION=$current_version
BUILD=$next_build
SOURCE_HASH=$current_source_hash
EOF

echo "Preparing $APP_NAME version $current_version build $next_build..."

echo "Building release binary..."
swift build -c release >/dev/null

BUILD_BIN_DIR="$(swift build -c release --show-bin-path)"
EXECUTABLE_PATH="$BUILD_BIN_DIR/PhotoSortHelper"
RESOURCE_BUNDLE_PATH="$BUILD_BIN_DIR/PhotoSortHelper_PhotoSortHelper.bundle"
ICONSET_SOURCE_DIR="$ROOT_DIR/Sources/PhotoSortHelper/Assets.xcassets/AppIcon.appiconset"
ICONSET_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/photosort-icon.XXXXXX")"
ICONSET_TMP_DIR="$ICONSET_TMP_ROOT/AppIcon.iconset"

cleanup() {
    rm -rf "$ICONSET_TMP_ROOT"
}
trap cleanup EXIT

if [[ ! -f "$EXECUTABLE_PATH" ]]; then
    echo "Missing executable at: $EXECUTABLE_PATH" >&2
    exit 1
fi

if [[ ! -d "$RESOURCE_BUNDLE_PATH" ]]; then
    echo "Missing resource bundle at: $RESOURCE_BUNDLE_PATH" >&2
    exit 1
fi

if [[ ! -d "$ICONSET_SOURCE_DIR" ]]; then
    echo "Missing app icon source set at: $ICONSET_SOURCE_DIR" >&2
    exit 1
fi

echo "Creating app bundle at: $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$EXECUTABLE_PATH" "$APP_DIR/Contents/MacOS/PhotoSortHelper"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp -R "$RESOURCE_BUNDLE_PATH" "$APP_DIR/Contents/Resources/"
chmod +x "$APP_DIR/Contents/MacOS/PhotoSortHelper"

echo "Generating AppIcon.icns..."
mkdir -p "$ICONSET_TMP_DIR"
cp "$ICONSET_SOURCE_DIR"/icon_*.png "$ICONSET_TMP_DIR/"
iconutil -c icns "$ICONSET_TMP_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "Code-signing app bundle..."
codesign --force --deep --sign - "$APP_DIR"

echo "Done."
echo "App: $APP_DIR"
echo "Version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
echo "Build: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Contents/Info.plist")"
