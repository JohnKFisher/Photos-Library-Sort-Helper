#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INFO_PLIST_PATH="${INFO_PLIST_PATH:-$ROOT_DIR/Resources/Info.plist}"

MARKETING_VERSION="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST_PATH"
)"
BUILD_NUMBER="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST_PATH"
)"

IFS='.' read -r MAJOR MINOR PATCH <<<"$MARKETING_VERSION"
if [[ -z "${MAJOR:-}" || -z "${MINOR:-}" || -z "${PATCH:-}" ]]; then
    echo "Expected CFBundleShortVersionString in MAJOR.MINOR.PATCH form, got: $MARKETING_VERSION" >&2
    exit 1
fi

if ! [[ "$MAJOR" =~ ^[0-9]+$ && "$MINOR" =~ ^[0-9]+$ && "$PATCH" =~ ^[0-9]+$ && "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "Version and build must be numeric. Got version=$MARKETING_VERSION build=$BUILD_NUMBER" >&2
    exit 1
fi

NEXT_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"
NEXT_BUILD="$((BUILD_NUMBER + 1))"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT_VERSION" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_BUILD" "$INFO_PLIST_PATH"

echo "Updated $INFO_PLIST_PATH"
echo "Previous version: $MARKETING_VERSION ($BUILD_NUMBER)"
echo "Next version: $NEXT_VERSION ($NEXT_BUILD)"
