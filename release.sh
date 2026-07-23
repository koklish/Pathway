#!/bin/bash
# Выпускает релиз: поднимает версию, собирает подписанный бандл, публикует на GitHub.
#
# Использование: ./release.sh 1.1.0
set -euo pipefail

VERSION="${1:-}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Проводник"
PLIST="$ROOT/Resources/Info.plist"

if [ -z "$VERSION" ]; then
    echo "Использование: ./release.sh <версия>, например ./release.sh 1.1.0" >&2
    exit 1
fi

# Версия должна выглядеть как 1.2.3: по ней приложение решает, обновляться ли
# (AppVersion.swift разбирает именно этот формат), и разбор нестандартной строки
# просто вернёт nil — обновления тихо перестанут приходить.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Версия должна быть вида 1.2.3, получено: $VERSION" >&2
    exit 1
fi

CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
# Понижение версии опубликуется без ошибки, но обновление не придёт никому:
# и UpdateService, и UpdateInstaller требуют строго новее — а откатить уже
# опубликованный релиз нельзя. Сравниваем через sort -V, а не строкой: строковое
# сравнение поставило бы «1.10.0» перед «1.9.0» — та же ловушка, которую
# AppVersion.swift разбирает почисленно по компонентам. BSD sort -V из macOS
# (проверено: 2.3-Apple) на тройках X.Y.Z даёт тот же порядок, что и сравнение
# AppVersion, поэтому здесь не нужен отдельный числовой разбор в bash.
if [ "$CURRENT_VERSION" = "$VERSION" ] || \
   [ "$(printf '%s\n%s\n' "$CURRENT_VERSION" "$VERSION" | sort -V | tail -1)" != "$VERSION" ]; then
    echo "Версия $VERSION не выше текущей $CURRENT_VERSION." >&2
    exit 1
fi

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "Рабочее дерево не чистое. Закоммитьте или отложите изменения." >&2
    exit 1
fi

# Релиз пушится в main жёстко (см. ниже) — если запустить скрипт с другой ветки,
# коллеги получат впечатление, что релиз вышел из main, хотя в нём не будет
# незакоммиченных туда изменений текущей ветки. Лучше остановиться заранее, чем
# разбираться потом, откуда в main взялся релизный коммит с чужой веткой в предках.
CURRENT_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo "Релизы выпускаются только с ветки main, сейчас: $CURRENT_BRANCH" >&2
    exit 1
fi

if git -C "$ROOT" rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "Тег v$VERSION уже существует." >&2
    exit 1
fi

if ! command -v gh >/dev/null; then
    echo "Нужен GitHub CLI: brew install gh" >&2
    exit 1
fi

# Проверяем авторизацию и сеть заранее, а не в момент публикации: если рухнуть
# на gh release create, тег и коммит версии уже будут в истории — откатывать
# опубликованный (запушенный) тег куда болезненнее, чем отказать сразу.
if ! gh auth status >/dev/null 2>&1; then
    echo "GitHub CLI не авторизован или недоступна сеть: gh auth status" >&2
    exit 1
fi

# Локальный коммит и тег — сделаны они или нет к моменту сбоя. Если скрипт
# упадёт ниже (сборка, подпись, публикация) уже после того, как коммит и тег
# созданы, но раньше, чем что-либо ушло в origin, откатываем оба — иначе в
# рабочем дереве останется тег без опубликованного релиза и коммит версии,
# которые придётся руками распутывать перед повторным запуском. Один общий
# trap на EXIT, а не отдельные на каждом этапе: несколько trap на один сигнал
# в bash не складываются, следующий просто заменяет предыдущий.
COMMITTED=0
TAGGED=0
PUSHED=0
BUILD_DIR=""
cleanup_on_failure() {
    local status=$?
    [ -n "$BUILD_DIR" ] && rm -rf "$BUILD_DIR"
    if [ "$status" -eq 0 ]; then
        return
    fi
    if [ "$PUSHED" -eq 1 ]; then
        # Что-то уже ушло в origin (main и/или тег) — откатывать локально
        # бессмысленно и опасно: это разошлось бы с тем, что видит GitHub.
        # Дальше разбираться вручную безопаснее, чем скрипту гадать, что откатывать.
        echo "Сбой после начала публикации: origin уже мог получить main и/или тег v$VERSION." >&2
        echo "Проверьте состояние вручную: git log origin/main, git ls-remote --tags origin, gh release list." >&2
        return
    fi
    if [ "$TAGGED" -eq 1 ]; then
        git -C "$ROOT" tag -d "v$VERSION" >/dev/null 2>&1 || true
    fi
    if [ "$COMMITTED" -eq 1 ]; then
        git -C "$ROOT" reset --hard HEAD~1 >/dev/null 2>&1 || true
    fi
    echo "Сбой до публикации — локальный коммит версии и тег откачены, рабочее дерево возвращено." >&2
}
trap cleanup_on_failure EXIT

# Версия проставляется в Info.plist и в тег из одного значения: разойдись они,
# коллеги получали бы предложение обновиться, уже стоя на новой версии.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
# CFBundleVersion — число коммитов; это не гарантированная монотонность, а
# приближение: после rebase или squash счётчик может уменьшиться. Вреда от
# этого нет — везде сравнение идёт по CFBundleShortVersionString выше, а
# CFBundleVersion нигде не читается, — но полагаться на его рост нельзя.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git -C "$ROOT" rev-list --count HEAD)" "$PLIST"

git -C "$ROOT" add "$PLIST"
git -C "$ROOT" commit -m "Версия $VERSION" >/dev/null
COMMITTED=1
git -C "$ROOT" tag "v$VERSION"
TAGGED=1

# Пробел перед многоточием — не стиль, а необходимость: системный /bin/bash на
# macOS (3.2, лицензия вынуждает Apple держать его старым) не всегда верно
# режет многобайтовый UTF-8-символ сразу после имени переменной под set -u и
# падает с «unbound variable», хотя переменная на месте.
echo "Собираю $APP_NAME $VERSION …"

# Собираем во временной директории, а не через build-app.sh: тот закрывает
# запущенное приложение и перезаписывает /Applications. Выпуск релиза не должен
# трогать рабочую копию разработчика.
BUILD_DIR="$(mktemp -d)"
APP="$BUILD_DIR/$APP_NAME.app"

swift build -c release --product Pathway

if [ ! -f "$ROOT/Resources/AppIcon.icns" ] || [ "$ROOT/Resources/AppIcon.svg" -nt "$ROOT/Resources/AppIcon.icns" ]; then
    "$ROOT/Tools/make-icon.sh"
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Pathway" "$APP/Contents/MacOS/Pathway"
cp "$PLIST" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Тот же идентификатор подписи, что в build-app.sh: macOS помнит выданные
# разрешения по идентичности подписи, и обновлённая копия должна остаться для
# системы тем же приложением — иначе доступ к папкам и Связке ключей спросят заново.
codesign --force --sign - --identifier com.pathway.filemanager \
    --entitlements "$ROOT/Resources/Pathway.entitlements" "$APP"

# Подпись проверяем сразу — установщик коллег тоже вызовет codesign --verify,
# и лучше узнать о сломанной подписи здесь, чем после того, как архив уже
# опубликован и коллеги начали его скачивать.
codesign --verify --deep --strict "$APP"

ARCHIVE="$BUILD_DIR/$APP_NAME-$VERSION.zip"
# ditto, а не zip: сохраняет расширенные атрибуты и симлинки внутри бандла,
# без которых подпись развалится.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

# Заметки к выпуску — из коммитов после прошлого тега (не включая свежий
# коммит версии, который ничего не рассказывает о самом релизе).
PREVIOUS_TAG="$(git -C "$ROOT" describe --tags --abbrev=0 HEAD~1 2>/dev/null || true)"
if [ -n "$PREVIOUS_TAG" ]; then
    NOTES="$(git -C "$ROOT" log --pretty='- %s' "$PREVIOUS_TAG"..HEAD~1)"
else
    NOTES="Первый выпуск."
fi
# Диапазон коммитов может оказаться пустым, если релиз выпускают сразу после
# предыдущего без новых изменений: --notes "" не падает, но публикует релиз
# с пустым описанием, будто про него забыли. Подставляем понятный запасной текст.
if [ -z "$NOTES" ]; then
    NOTES="Без изменений в коде со времени предыдущего релиза."
fi

# Заметки накопительные: тело релиза содержит не только свои изменения, но и
# блоки предыдущих версий.
#
# Причина не в оформлении, а в том, что приложение спрашивает GitHub только про
# ПОСЛЕДНИЙ релиз (/releases/latest). Коллега, пропустивший выпуск, о нём
# никогда не узнает: обновившись с 1.1.1 сразу на 1.1.3, он увидит заметки 1.1.3
# и ничего про 1.1.2. Накопление в теле лечит это для всех уже установленных
# копий — им не нужно ничего обновлять, они просто показывают присланный текст.
#
# Заголовок вида «## 1.1.2» выбран так, чтобы обе стороны читались:
# ReleaseNotes.parse в старых версиях снимает решётки и покажет номер отдельной
# строкой списка, новые — сгруппируют пункты в блоки по версиям.
HISTORY_DEPTH=5
NOTES="## $VERSION
$NOTES"
PREVIOUS_NOTES=""
# Идём по тегам от свежего к старому, пропуская тот, что поставлен этим запуском.
for TAG in $(git -C "$ROOT" tag --sort=-v:refname | grep -v "^v$VERSION$" | head -n "$HISTORY_DEPTH"); do
    # Тело берём с GitHub, а не пересобираем из коммитов: опубликованные заметки
    # владелец мог отредактировать руками, и пересборка затёрла бы правку тем,
    # что было в сообщениях коммитов.
    BODY="$(gh release view "$TAG" --json body --jq .body 2>/dev/null || true)"
    [ -z "$BODY" ] && continue
    # Из накопительного тела берём только собственный блок релиза: иначе история
    # каждого следующего выпуска дублировала бы всю предыдущую целиком.
    BODY="$(printf '%s\n' "$BODY" | awk '/^## /{ if (seen++) exit; next } { print }')"
    BODY="$(printf '%s\n' "$BODY" | sed '/^[[:space:]]*$/d')"
    [ -z "$BODY" ] && continue
    PREVIOUS_NOTES="$PREVIOUS_NOTES
## ${TAG#v}
$BODY"
done
if [ -n "$PREVIOUS_NOTES" ]; then
    NOTES="$NOTES
$PREVIOUS_NOTES"
fi

echo "Публикую релиз…"
# С этой строки откат уже не имеет смысла — если что-то пойдёт не так дальше,
# origin мог получить часть изменений, и обработчик выше переходит в режим
# «сообщить, а не чинить». Помечаем это до первого push, а не после гонки
# с сетью: если push оборвётся ровно на середине передачи, факт попытки уже
# должен быть учтён.
PUSHED=1
git -C "$ROOT" push origin main
git -C "$ROOT" push origin "v$VERSION"
gh release create "v$VERSION" "$ARCHIVE" \
    --title "$APP_NAME $VERSION" \
    --notes "$NOTES"

echo "Готово: версия $VERSION опубликована."
echo "Коллеги увидят предложение обновиться в течение суток."
