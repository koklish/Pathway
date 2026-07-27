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

BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Pathway" "$APP/Contents/MacOS/Pathway"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ресурсные бандлы таргетов (заготовки документов в Pathway_PathwayCore.bundle).
# Без этого шага Bundle.module не находит бандл и падает с fatalError внутри
# сгенерированного SPM аксессора — причём не при запуске, а при первом создании
# документа, поэтому сборка выглядит рабочей и ошибка уезжает к коллегам.
#
# Именно Contents/Resources, а не рядом с бинарником: Bundle.module проверяет
# Bundle.main.resourceURL первым, а в Contents/MacOS codesign отказывается
# подписывать — «bundle format unrecognized», своего Info.plist у SPM-бандла нет.
#
# Копируются все *.bundle, а не известный по имени: ресурсы в новом таргете
# иначе повторили бы ту же ошибку молча.
for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done

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

# Заготовки проверяем в собранном бандле, а не только тестами: тесты запускаются
# из .build, где ресурсный бандл лежит рядом с тестовым бинарником и находится
# всегда. Забытый шаг копирования выше они не заметили бы — ровно так версия 1.2.0
# и уехала с крашем при создании документа, при 501 зелёном тесте.
"$ROOT/Tools/check-bundle.sh" "$APP"

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
