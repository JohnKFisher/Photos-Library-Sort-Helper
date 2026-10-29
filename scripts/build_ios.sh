#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
./scripts/bump_build_number.sh

has_destination=false
for argument in "$@"; do
    if [[ "$argument" == "-destination" || "$argument" == -destination=* ]]; then
        has_destination=true
        break
    fi
done

if [[ "$has_destination" == true ]]; then
    exec xcodebuild -project iOSApp/PhotosSort.xcodeproj -scheme PhotosSort "$@"
fi

exec xcodebuild -project iOSApp/PhotosSort.xcodeproj -scheme PhotosSort -destination 'generic/platform=iOS Simulator' "$@"
