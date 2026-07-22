#!/bin/bash
# Собирает установочный образ «Проводник.dmg» в оформлении из макета:
# окно с градиентным фоном, иконка приложения слева, «Программы» справа.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Проводник"
VOLUME_NAME="Проводник"
APP="$ROOT/build/$APP_NAME.app"
DMG="$ROOT/build/$APP_NAME.dmg"
STAGING="$ROOT/build/dmg-staging"

# Геометрия окна из макета: 640 × 420, из них 32 точки — полоса заголовка.
WIN_W=640
WIN_H=388
ICON_SIZE=132

"$ROOT/build-app.sh" "$CONFIG"

echo "Готовлю содержимое образа…"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING/.background"

cp -R "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Программы"

# На Retina-экране WebKit отдаёт снимок в удвоении — для фона это кстати:
# Finder растягивает картинку по размеру окна в точках, а лишние пиксели дают
# чёткость. Если рендер вышел одинарным, дотягиваем до 2× явно.
swift "$ROOT/Tools/render-html.swift" \
    "$ROOT/Resources/dmg-background.html" \
    "$STAGING/.background/background.png" \
    "$WIN_W" "$WIN_H"

BG_W="$(sips -g pixelWidth "$STAGING/.background/background.png" | awk '/pixelWidth/{print $2}')"
if [ "$BG_W" -lt "$((WIN_W * 2))" ]; then
    sips -z "$((WIN_H * 2))" "$((WIN_W * 2))" "$STAGING/.background/background.png" >/dev/null
fi

# Временный образ, доступный на запись: в нём расставляем иконки, затем сжимаем.
TEMP_DMG="$ROOT/build/temp.dmg"
rm -f "$TEMP_DMG"
hdiutil create -srcfolder "$STAGING" -volname "$VOLUME_NAME" \
    -fs HFS+ -fsargs "-c c=64,a=16,e=16" -format UDRW \
    -size 200m "$TEMP_DMG" >/dev/null

# Точку монтирования узнаём у самой системы, а не собираем из имени тома:
# если том с таким именем уже подключён, macOS смонтирует наш как «Проводник 1».
# Тогда путь «/Volumes/Проводник» указывал бы на чужой том, отцепить наш не вышло
# бы, и сжатие упало бы на занятом образе.
MOUNT_DIR="$(hdiutil attach "$TEMP_DMG" -readwrite -noverify -noautoopen \
    | awk -F'\t' '/\/Volumes\//{print $NF; exit}')"

if [ -z "$MOUNT_DIR" ] || [ ! -d "$MOUNT_DIR" ]; then
    echo "Не удалось смонтировать временный образ" >&2
    exit 1
fi

# Имя тома в пути может отличаться от VOLUME_NAME из-за того же суффикса,
# а AppleScript обращается к диску по имени — берём фактическое.
MOUNTED_NAME="$(basename "$MOUNT_DIR")"

# Что бы дальше ни случилось, том не должен остаться подключённым: занятый образ
# нельзя ни сжать, ни пересобрать при следующем запуске.
trap 'hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true' EXIT

# Finder не всегда успевает увидеть только что смонтированный том.
for _ in $(seq 1 20); do
    [ -d "$MOUNT_DIR" ] && break
    sleep 0.5
done

echo "Расставляю иконки…"
osascript <<EOF
tell application "Finder"
    tell disk "$MOUNTED_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- Координаты левого верхнего угла и размера окна на экране.
        set the bounds of container window to {200, 120, $((200 + WIN_W)), $((120 + WIN_H + 32))}

        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to $ICON_SIZE
        set background picture of opts to file ".background:background.png"

        -- Приложение слева, «Программы» справа — как на макете.
        set position of item "$APP_NAME.app" of container window to {150, 180}
        set position of item "Программы" of container window to {490, 180}

        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

# Права на чтение всем, иначе у скачавшего образ иконки могут не открыться.
chmod -Rf go-w "$MOUNT_DIR" 2>/dev/null || true
sync

hdiutil detach "$MOUNT_DIR" >/dev/null
trap - EXIT

echo "Сжимаю образ…"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

rm -f "$TEMP_DMG"
rm -rf "$STAGING"

echo "Готово: $DMG"
