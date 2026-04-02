#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

INFO_PLIST_PATH="${INFO_PLIST_PATH:-$ROOT_DIR/Resources/Info.plist}"
DISPLAY_NAME="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO_PLIST_PATH"
)"
EXECUTABLE_NAME="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST_PATH"
)"
APP_NAME="${APP_NAME:-$DISPLAY_NAME.app}"
APP_DIR="${APP_DIR:-$ROOT_DIR/dist/$APP_NAME}"
APP_NAME="$(basename "$APP_DIR")"
VERSION_STATE_DIR="${VERSION_STATE_DIR:-$ROOT_DIR/.build}"
VERSION_STATE_FILE="${VERSION_STATE_FILE:-$VERSION_STATE_DIR/version-build-state}"
ARM_TRIPLE="${ARM_TRIPLE:-arm64-apple-macosx14.0}"
X86_TRIPLE="${X86_TRIPLE:-x86_64-apple-macosx14.0}"

increment_patch_version() {
    local version="$1"
    local major=""
    local minor=""
    local patch=""
    local extra=""

    IFS=. read -r major minor patch extra <<< "$version"
    if [[ -n "$extra" || -z "$major" || -z "$minor" || -z "$patch" ]]; then
        echo "Unsupported version format: $version" >&2
        exit 1
    fi
    if [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ || ! "$patch" =~ ^[0-9]+$ ]]; then
        echo "Unsupported version format: $version" >&2
        exit 1
    fi

    printf "%s.%s.%s\n" "$major" "$minor" "$((patch + 1))"
}

base_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST_PATH")"

last_base_version=""
last_marketing_version=""
last_build="0"
if [[ -f "$VERSION_STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$VERSION_STATE_FILE"
    last_base_version="${BASE_VERSION:-}"
    last_marketing_version="${LAST_MARKETING_VERSION:-}"
    last_build="${BUILD:-0}"
fi

if [[ "$base_version" == "$last_base_version" && "$last_build" =~ ^[0-9]+$ ]]; then
    next_build="$((last_build + 1))"
    version_seed="${last_marketing_version:-$base_version}"
    next_marketing_version="$(increment_patch_version "$version_seed")"
else
    next_build="1"
    next_marketing_version="$base_version"
fi

mkdir -p "$VERSION_STATE_DIR"
cat >"$VERSION_STATE_FILE" <<EOF
BASE_VERSION=$base_version
LAST_MARKETING_VERSION=$next_marketing_version
BUILD=$next_build
EOF

echo "Preparing $APP_NAME version $next_marketing_version build $next_build..."

echo "Building release binaries..."
swift build -c release --triple "$ARM_TRIPLE" >/dev/null
swift build -c release --triple "$X86_TRIPLE" >/dev/null

ARM_BIN_DIR="$(swift build -c release --triple "$ARM_TRIPLE" --show-bin-path)"
X86_BIN_DIR="$(swift build -c release --triple "$X86_TRIPLE" --show-bin-path)"
ARM_EXECUTABLE_PATH="$ARM_BIN_DIR/$EXECUTABLE_NAME"
X86_EXECUTABLE_PATH="$X86_BIN_DIR/$EXECUTABLE_NAME"
RESOURCE_BUNDLE_PATH="$ARM_BIN_DIR/${EXECUTABLE_NAME}_${EXECUTABLE_NAME}.bundle"
ICONSET_SOURCE_DIR="$ROOT_DIR/Sources/PhotoSortHelper/Assets.xcassets/AppIcon.appiconset"
ICONSET_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/photosort-icon.XXXXXX")"
ICONSET_TMP_DIR="$ICONSET_TMP_ROOT/AppIcon.iconset"

cleanup() {
    rm -rf "$ICONSET_TMP_ROOT"
}
trap cleanup EXIT

if [[ ! -f "$ARM_EXECUTABLE_PATH" ]]; then
    echo "Missing arm64 executable at: $ARM_EXECUTABLE_PATH" >&2
    exit 1
fi

if [[ ! -f "$X86_EXECUTABLE_PATH" ]]; then
    echo "Missing x86_64 executable at: $X86_EXECUTABLE_PATH" >&2
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
mkdir -p "$(dirname "$APP_DIR")"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

lipo -create "$ARM_EXECUTABLE_PATH" "$X86_EXECUTABLE_PATH" -output "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
cp "$INFO_PLIST_PATH" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $next_marketing_version" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $next_build" "$APP_DIR/Contents/Info.plist"
cp -R "$RESOURCE_BUNDLE_PATH" "$APP_DIR/Contents/Resources/"
chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"

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
