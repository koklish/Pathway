#!/bin/bash
# Собирает Resources/AppIcon.icns из Resources/AppIcon.svg.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/Resources/AppIcon.svg"
ICONSET="$(mktemp -d)/AppIcon.iconset"
OUT="$ROOT/Resources/AppIcon.icns"

mkdir -p "$ICONSET"

# WebKit рисует на Retina-экране с удвоением, поэтому просим половину нужного
# размера и получаем ровно тот, что заказывали. Проверяем это ниже.
render() {
    local target="$1" name="$2"
    swift "$ROOT/Tools/render-icon.swift" "$SVG" "$ICONSET/$name" "$((target / 2))"
    local actual
    actual="$(sips -g pixelWidth "$ICONSET/$name" | awk '/pixelWidth/{print $2}')"
    if [ "$actual" != "$target" ]; then
        # Экран без удвоения или другое поведение WebKit — доводим размер явно.
        sips -z "$target" "$target" "$ICONSET/$name" >/dev/null
    fi
}

# Набор размеров, который требует iconutil.
render 16    icon_16x16.png
render 32    icon_16x16@2x.png
render 32    icon_32x32.png
render 64    icon_32x32@2x.png
render 128   icon_128x128.png
render 256   icon_128x128@2x.png
render 256   icon_256x256.png
render 512   icon_256x256@2x.png
render 512   icon_512x512.png
render 1024  icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$(dirname "$ICONSET")"

echo "Готово: $OUT"
