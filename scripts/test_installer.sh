#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/EdgeProfileDock.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
PKG="${1:-$ROOT/build/EdgeProfileDock-$VERSION.pkg}"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/edgeprofiledock-installer-test.XXXXXXXX")"
cleanup() {
    local epd_exit_code=$?
    find "$WORK" -depth -delete || true
    exit "$epd_exit_code"
}
trap cleanup EXIT

echo "==> 检查安装包校验与内容"
(cd "$(dirname "$PKG")" && /usr/bin/shasum -a 256 -c "$(basename "$PKG").sha256")
/usr/sbin/pkgutil --expand-full "$PKG" "$WORK/expanded"
COMPONENT="$WORK/expanded/EdgeProfileDock-component.pkg"
PAYLOAD_APP="$COMPONENT/Payload/EdgeProfileDock.app"
SCRIPTS="$COMPONENT/Scripts"
test -x "$SCRIPTS/preinstall"
test -s "$SCRIPTS/signature-requirement.txt"
python3 - "$WORK/expanded/Distribution" "$COMPONENT/PackageInfo" "$COMPONENT/Payload" "$VERSION" "$MIN_OS" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

distribution = ET.parse(sys.argv[1]).getroot()
package = ET.parse(sys.argv[2]).getroot()
payload = Path(sys.argv[3])
version, minimum_os = sys.argv[4:]
assert distribution.find('title').text == 'EdgeProfileDock'
assert distribution.find('options').get('hostArchitectures') == 'arm64'
assert distribution.find('./volume-check/allowed-os-versions/os-version').get('min') == minimum_os
domains = distribution.find('domains')
assert domains.get('enable_anywhere') == 'false'
assert domains.get('enable_currentUserHome') == 'false'
assert domains.get('enable_localSystem') == 'true'
assert any(
    ref.get('id') == 'com.local.EdgeProfileDock.pkg'
    and ref.find('./must-close/app') is not None
    and ref.find('./must-close/app').get('id') == 'com.local.EdgeProfileDock'
    for ref in distribution.findall('pkg-ref')
)
assert package.get('identifier') == 'com.local.EdgeProfileDock.pkg'
assert package.get('version') == version
assert package.get('install-location') == '/Applications'
assert package.get('relocatable') == 'false'
assert package.get('auth') == 'root'
assert package.find('./scripts/preinstall').get('file') == './preinstall'
assert package.find('./upgrade-bundle/bundle').get('id') == 'com.local.EdgeProfileDock'
assert package.find('./strict-identifier/bundle').get('id') == 'com.local.EdgeProfileDock'
assert [p.name for p in payload.iterdir()] == ['EdgeProfileDock.app']
print('安装目标、系统要求、退出提示和组件元数据正确')
PY
/usr/bin/diff -qr "$APP" "$PAYLOAD_APP"
/usr/bin/codesign --verify --strict -R="$(cat "$SCRIPTS/signature-requirement.txt")" "$PAYLOAD_APP"

echo "==> 检查安装前保护"
FAKE_VOLUME="$WORK/target volume"
FAKE_APP="$FAKE_VOLUME/Applications/EdgeProfileDock.app"
mkdir -p "$FAKE_VOLUME/Applications"
"$SCRIPTS/preinstall" ignored ignored "$FAKE_VOLUME"
/usr/bin/ditto "$APP" "$FAKE_APP"
"$SCRIPTS/preinstall" ignored ignored "$FAKE_VOLUME"
/usr/bin/codesign --force --deep --sign - "$FAKE_APP" >/dev/null 2>&1
if "$SCRIPTS/preinstall" ignored ignored "$FAKE_VOLUME" >/dev/null 2>&1; then
    echo '错误：不同签名未被拒绝。' >&2
    exit 1
fi
/usr/bin/codesign --verify --strict "$FAKE_APP"
mv "$FAKE_APP" "$WORK/other.app"
ln -s "$WORK/other.app" "$FAKE_APP"
if "$SCRIPTS/preinstall" ignored ignored "$FAKE_VOLUME" >/dev/null 2>&1; then
    echo '错误：符号链接未被拒绝。' >&2
    exit 1
fi
mkdir -p "$WORK/scripts-without-requirement"
cp "$SCRIPTS/preinstall" "$WORK/scripts-without-requirement/preinstall"
if "$WORK/scripts-without-requirement/preinstall" ignored ignored "$FAKE_VOLUME" >/dev/null 2>&1; then
    echo '错误：缺少签名要求时未停止安装。' >&2
    exit 1
fi

echo "==> 检查系统安装器可读取安装项目"
/usr/sbin/installer -pkg "$PKG" -target / -showChoicesXML > "$WORK/choices.plist"
/usr/bin/plutil -lint "$WORK/choices.plist"
python3 - "$WORK/choices.plist" <<'PY'
import plistlib
import sys

choices = plistlib.load(open(sys.argv[1], 'rb'))
def walk(nodes):
    for node in nodes:
        yield node
        yield from walk(node.get('childItems', []))
assert any(
    choice.get('choiceIdentifier') == 'com.local.EdgeProfileDock.pkg'
    and choice.get('choiceIsSelected')
    and choice.get('choiceIsEnabled')
    for choice in walk(choices)
)
PY
echo "==> 安装包隔离检查通过"
