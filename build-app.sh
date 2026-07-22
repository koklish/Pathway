#!/bin/bash
# Собирает «Проводник.app» — бандл приложения для запуска в macOS.
#
# Внутреннее имя продукта остаётся Pathway (так называются таргеты и исполняемый
# файл), пользователю же везде видно «Проводник».
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Проводник.app"
# Готовый бандл ставится в /Applications: копия там — единственная, которую
# запускают из Launchpad и Spotlight. Иначе легко проверять вчерашнюю сборку,
# ведь обе копии имеют один bundle id и внешне неразличимы.
INSTALLED="/Applications/Проводник.app"

swift build -c "$CONFIG" --product Pathway

# Иконку пересобираем, только если SVG новее готового icns: рендер занимает секунды.
if [ ! -f "$ROOT/Resources/AppIcon.icns" ] || [ "$ROOT/Resources/AppIcon.svg" -nt "$ROOT/Resources/AppIcon.icns" ]; then
    "$ROOT/Tools/make-icon.sh"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c "$CONFIG" --show-bin-path)/Pathway" "$APP/Contents/MacOS/Pathway"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Подписываем бандл целиком. Без этого шага подпись ставит линковщик — только на
# исполняемый файл, с идентификатором «Pathway» и без запечатанных ресурсов.
#
# macOS запоминает выданные разрешения (доступ к папкам в TCC, доступ к записям
# Связки ключей) по идентичности подписи. Явный --identifier привязывает её к
# bundle id вместо имени файла, поэтому пересобранная копия остаётся для системы
# тем же приложением и не спрашивает подтверждений заново.
#
# Entitlements объявляют работу вне песочницы: без них система считает намерения
# приложения неопределёнными и чаще переспрашивает про доступ к файлам.
codesign --force --sign - --identifier com.pathway.filemanager \
    --entitlements "$ROOT/Resources/Pathway.entitlements" "$APP"

# Запущенную копию сначала закрываем — иначе замена бандла на живом процессе
# оставит приложение в нерабочем состоянии.
if pgrep -x Pathway > /dev/null; then
    osascript -e 'quit app "Pathway"' 2>/dev/null || true
    # Ждём завершения, но не бесконечно: зависший процесс не должен рушить сборку.
    for _ in $(seq 20); do
        pgrep -x Pathway > /dev/null || break
        sleep 0.25
    done
fi

rm -rf "$INSTALLED"
cp -R "$APP" "$INSTALLED"

echo "Готово: $INSTALLED"
