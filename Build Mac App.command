#!/bin/zsh
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
OUTPUT_DIR="$HOME/Library/Developer/Builds/Photos Sort Helper"
APP_DIR="$OUTPUT_DIR/Photos Sort Helper.app"
DMG_PATH="$OUTPUT_DIR/Photos-Sort-Helper.dmg"

mkdir -p "$OUTPUT_DIR"

echo "Building Photos Sort Helper for macOS..."
echo "Output folder: $OUTPUT_DIR"
APP_DIR="$APP_DIR" DMG_PATH="$DMG_PATH" "$REPO_DIR/scripts/build_app.sh"

echo "Opening the build folder..."
open "$OUTPUT_DIR"
