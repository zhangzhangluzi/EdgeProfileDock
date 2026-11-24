#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/EdgeProfileDock.app}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
OUTPUT="${2:-$ROOT/build/EdgeProfileDock-$VERSION.pkg}"
OUTPUT_DIR="$(dirname "$OUTPUT")"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
OUTPUT="$OUTPUT_DIR/$(basename "$OUTPUT")"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "com.local.EdgeProfileDock" ]]
/usr/bin/codesign --verify --strict "$APP"
/usr/bin/lipo -verify_arch arm64 "$APP/Contents/MacOS/EdgeProfileDock"
requirement="$(/usr/bin/codesign -d -r- "$APP" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
[[ -n "$requirement" ]]

WORK="$(mktemp -d "$OUTPUT_DIR/.installer.XXXXXXXX")"
cleanup() {
    local epd_exit_code=$?
    find "$WORK" -depth -delete || true
    exit "$epd_exit_code"
}
trap cleanup EXIT
mkdir -p "$WORK/root" "$WORK/scripts"
/usr/bin/ditto --norsrc "$APP" "$WORK/root/EdgeProfileDock.app"
cp "$ROOT/scripts/installer/preinstall" "$WORK/scripts/preinstall"
chmod 755 "$WORK/scripts/preinstall"
printf '%s\n' "$requirement" > "$WORK/scripts/signature-requirement.txt"

/usr/bin/pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist"
python3 - "$WORK/components.plist" "$WORK/requirements.plist" "$MIN_OS" <<'PY'
import plistlib
import sys
from pathlib import Path

component_path = Path(sys.argv[1])
components = plistlib.loads(component_path.read_bytes())
if len(components) != 1 or components[0].get("RootRelativeBundlePath") != "EdgeProfileDock.app":
    raise SystemExit("安装包组件与预期不符")
components[0].update({
    "BundleIsRelocatable": False,
    "BundleIsVersionChecked": True,
    "BundleHasStrictIdentifier": True,
    "BundleOverwriteAction": "upgrade",
})
component_path.write_bytes(plistlib.dumps(components))
Path(sys.argv[2]).write_bytes(plistlib.dumps({"os": [sys.argv[3]], "arch": ["arm64"]}))
PY

/usr/bin/pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" \
    --scripts "$WORK/scripts" --install-location /Applications \
    --identifier com.local.EdgeProfileDock.pkg --version "$VERSION" "$WORK/EdgeProfileDock-component.pkg"
/usr/bin/productbuild --synthesize --product "$WORK/requirements.plist" \
    --package "$WORK/EdgeProfileDock-component.pkg" "$WORK/Distribution.xml"
python3 - "$WORK/Distribution.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

path = Path(sys.argv[1])
tree = ET.parse(path)
root = tree.getroot()
title = root.find("title")
if title is None:
    title = ET.Element("title")
    root.insert(0, title)
title.text = "EdgeProfileDock"
options = root.find("options")
if options is None:
    options = ET.SubElement(root, "options")
options.set("customize", "never")
domains = root.find("domains")
if domains is None:
    domains = ET.SubElement(root, "domains")
domains.attrib.update({
    "enable_anywhere": "false",
    "enable_currentUserHome": "false",
    "enable_localSystem": "true",
})
package = ET.SubElement(root, "pkg-ref", {"id": "com.local.EdgeProfileDock.pkg"})
must_close = ET.SubElement(package, "must-close")
ET.SubElement(must_close, "app", {"id": "com.local.EdgeProfileDock"})
tree.write(path, encoding="utf-8", xml_declaration=True)
PY

if [[ -n "${EPD_INSTALLER_IDENTITY:-}" ]]; then
    /usr/bin/productbuild --distribution "$WORK/Distribution.xml" --package-path "$WORK" \
        --sign "$EPD_INSTALLER_IDENTITY" "$WORK/EdgeProfileDock.pkg"
else
    /usr/bin/productbuild --distribution "$WORK/Distribution.xml" --package-path "$WORK" \
        "$WORK/EdgeProfileDock.pkg"
fi
mv "$WORK/EdgeProfileDock.pkg" "$OUTPUT"
(cd "$OUTPUT_DIR" && /usr/bin/shasum -a 256 "$(basename "$OUTPUT")") > "$OUTPUT.sha256"
echo "安装包: $OUTPUT"
echo "校验文件: $OUTPUT.sha256"
if [[ -z "${EPD_INSTALLER_IDENTITY:-}" ]]; then
    echo "安装包未使用 Developer ID Installer 签名，尚未经过 Apple 公证。"
fi
