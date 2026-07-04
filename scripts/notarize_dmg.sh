#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

DMG_PATH="${DMG_PATH:-$ROOT_DIR/dist/PhotosLibrarySortHelper-macos-universal.dmg}"

required_env=(
    APPLE_ID
    APPLE_TEAM_ID
    APPLE_APP_SPECIFIC_PASSWORD
)

for name in "${required_env[@]}"; do
    if [[ -z "${!name:-}" ]]; then
        echo "Missing required environment variable: $name" >&2
        exit 1
    fi
done

if [[ ! -f "$DMG_PATH" ]]; then
    echo "Missing DMG at: $DMG_PATH" >&2
    exit 1
fi

echo "Submitting DMG for notarization: $DMG_PATH"
xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

echo "Validating stapled DMG..."
xcrun stapler validate "$DMG_PATH"
spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"

echo "Notarized and stapled: $DMG_PATH"
