#!/bin/bash
# Собирает Pathway.app — бандл приложения для запуска в macOS.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Pathway.app"

swift build -c "$CONFIG" --product Pathway

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c "$CONFIG" --show-bin-path)/Pathway" "$APP/Contents/MacOS/Pathway"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "Готово: $APP"
