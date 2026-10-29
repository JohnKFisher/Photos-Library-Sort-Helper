#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CURRENT_BUILD="$(cat BUILD_NUMBER)"
if ! [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
    echo "BUILD_NUMBER must be numeric; got: $CURRENT_BUILD" >&2
    exit 1
fi
NEXT_BUILD="$((CURRENT_BUILD + 1))"
printf '%s\n' "$NEXT_BUILD" > BUILD_NUMBER
./scripts/prepare_version_metadata.sh
echo "BUILD_NUMBER: $CURRENT_BUILD -> $NEXT_BUILD"
