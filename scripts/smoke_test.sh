#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/EdgeProfileDock.app"
STUB="$APP/Contents/Resources/LauncherStub"

echo "==> 检查应用产物"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --verify --strict "$APP"
SIGNING_REQUIREMENT="$(/usr/bin/codesign -d -r- "$APP" 2>&1)"
[[ "$SIGNING_REQUIREMENT" == *$'\ndesignated => identifier "com.local.EdgeProfileDock" and certificate leaf = H"'* ]]
test -x "$APP/Contents/MacOS/EdgeProfileDock"
test -x "$STUB"
test -s "$APP/Contents/Resources/AppIcon.icns"
cmp "$ROOT/build/LauncherStub" "$STUB"

echo "==> 读取 Edge 资料"
python3 - <<'PY'
import json, os, sys
path = os.path.expanduser("~/Library/Application Support/Microsoft Edge/Local State")
if not os.path.exists(path):
    print("跳过：未找到 Edge 资料状态")
    sys.exit(0)
with open(path) as f:
    data = json.load(f)
cache = data.get("profile", {}).get("info_cache", {})
assert cache, "未找到资料"
for key, meta in cache.items():
    name = meta.get("name") or key
    print(f"  - {key}: {name}")
print(f"已读取 {len(cache)} 个资料")
PY

for launcher in "$@"; do
    echo "==> 检查启动器 $launcher"
    info="$launcher/Contents/Info.plist"
    /usr/bin/plutil -lint "$info"
    test "$(/usr/libexec/PlistBuddy -c 'Print :EPDOwner' "$info")" = EdgeProfileDock
    test "$(/usr/libexec/PlistBuddy -c 'Print :EPDWrapperStyle' "$info")" = window-dock
    test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$info")" = true
    case "$(/usr/libexec/PlistBuddy -c 'Print :EPDIconSource' "$info")" in
        local-avatar|initial) ;;
        *) exit 1 ;;
    esac
    test -s "$launcher/Contents/Resources/AppIcon.icns"
    cmp "$STUB" "$launcher/Contents/MacOS/EdgeProfileLauncher"
done

echo "==> 冒烟检查通过"
