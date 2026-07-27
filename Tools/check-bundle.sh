#!/bin/bash
# Проверяет, что собранный бандл содержит всё, без чего приложение падает уже
# у пользователя. Вызывается из build-app.sh и release.sh после подписи.
#
# Нужен отдельно от swift test: тесты идут из .build, где ресурсные бандлы SPM
# лежат рядом с тестовым бинарником, поэтому Bundle.module там находит их всегда.
# Ошибка сборки бандла для них невидима — версия 1.2.0 уехала к коллегам с
# крашем при создании документа при полностью зелёном прогоне.
set -euo pipefail

APP="${1:-}"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "Использование: check-bundle.sh <путь к .app>" >&2
    exit 1
fi

fail() { echo "Бандл собран неполно: $1" >&2; exit 1; }

[ -f "$APP/Contents/MacOS/Pathway" ] || fail "нет исполняемого файла"
[ -f "$APP/Contents/Info.plist" ] || fail "нет Info.plist"

# Ресурсный бандл PathwayCore с заготовками документов. Без него Bundle.module
# падает с fatalError — не при запуске, а при первом «Создать → документ»,
# поэтому сломанная сборка выглядит рабочей.
TEMPLATES="$APP/Contents/Resources/Pathway_PathwayCore.bundle/Templates"
[ -d "$TEMPLATES" ] || fail "нет заготовок документов (Pathway_PathwayCore.bundle)"

# Состав сверяем с DocumentTemplates.all: пункт меню без файла-заготовки даёт
# ошибку при создании документа, а не при сборке.
#
# Непустоту требуем со всех, кроме txt: пустой текстовый файл — нормальный
# документ, а контейнерные форматы нулевой длины Word и Pages считают
# повреждёнными (та же граница, что в TemplateResourcesTests).
for id in txt rtf docx xlsx pptx pages numbers key; do
    [ -f "$TEMPLATES/$id" ] || fail "нет заготовки $id"
    [ "$id" = "txt" ] || [ -s "$TEMPLATES/$id" ] || fail "заготовка $id пуста"
done

# LSFileQuarantineEnabled ломает самообновление целиком: скачанное через
# URLSession получило бы карантин, а подпись у нас ad-hoc — Gatekeeper не
# пропустил бы. Связь неочевидная, поэтому стережём её здесь.
if /usr/libexec/PlistBuddy -c "Print :LSFileQuarantineEnabled" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    fail "в Info.plist есть LSFileQuarantineEnabled — самообновление перестанет работать"
fi

echo "Проверка бандла пройдена."
