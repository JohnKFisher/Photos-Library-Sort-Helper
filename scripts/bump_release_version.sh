#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

MARKETING_VERSION="$(cat VERSION)"
BUILD_NUMBER="$(cat BUILD_NUMBER)"

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

printf '%s\n' "$NEXT_VERSION" > VERSION
printf '%s\n' "$NEXT_BUILD" > BUILD_NUMBER
./scripts/prepare_version_metadata.sh

echo "Updated root version authority."
echo "Previous version: $MARKETING_VERSION ($BUILD_NUMBER)"
echo "Next version: $NEXT_VERSION ($NEXT_BUILD)"
