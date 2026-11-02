#!/bin/bash
# Read-only artifact verification: never runs Installer's install operation.
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
package="${1:-dist/CodexResetBar-$version-macOS-universal.pkg}"
image="${2:-dist/CodexResetBar-$version-macOS-universal.dmg}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-reset-bar-verify.XXXXXX")"
mounted=false
cleanup() {
  if [[ "$mounted" == true ]]; then hdiutil detach "$work_dir/mount" -quiet; fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

pkgutil --expand-full "$package" "$work_dir/expanded"
installer -dominfo -pkg "$package" > "$work_dir/domains.txt"
installer -showChoicesXML -pkg "$package" -target CurrentUserHomeDirectory > "$work_dir/choices.plist"
python3 - "$work_dir" "$version" <<'PY'
from pathlib import Path
import plistlib
import sys
import xml.etree.ElementTree as ET

work, version = Path(sys.argv[1]), sys.argv[2]
expanded = work / "expanded"
distribution = ET.parse(expanded / "Distribution").getroot()
assert distribution.find("domains").attrib == {
    "enable_anywhere": "false", "enable_currentUserHome": "true", "enable_localSystem": "false"
}, "Only the current user's home installation domain may be enabled"
assert (work / "domains.txt").read_text().strip() == "CurrentUserHomeDirectory"
assert distribution.find("volume-check/allowed-os-versions/os-version").get("min") == "14.0"
assert distribution.find("pkg-ref/must-close/app").get("id") == "local.benxin.codex-reset-bar"
assert any(ref.get("version") == version for ref in distribution.findall("pkg-ref"))
resources = expanded / "Resources"
for element, filename in (("welcome", "welcome.html"), ("license", "license.txt"), ("conclusion", "conclusion.html")):
    assert distribution.find(element).get("file") == filename
    assert (resources / filename).is_file()
assert (resources / "license.txt").read_bytes() == Path("LICENSE").read_bytes()
assert (resources / "wechat-qr.png").read_bytes() == Path("assets/wechat-qr.png").read_bytes()
assert "wubenxincom" in (resources / "conclusion.html").read_text()
assert "2. 安装后双击启动" in (resources / "conclusion.html").read_text()

component = expanded / "CodexResetBar.pkg"
metadata = ET.parse(component / "PackageInfo").getroot()
assert metadata.get("version") == version
assert metadata.get("identifier") == "local.benxin.codex-reset-bar.pkg"
assert metadata.get("install-location") == "/"
assert metadata.find("relocate").find("bundle") is None, "App must not relocate to another user's or system copy"
# pkgbuild's `upgrade` action is documented to atomically replace the bundle.
assert metadata.find("upgrade-bundle/bundle").get("id") == "local.benxin.codex-reset-bar"
assert metadata.find("update-bundle/bundle") is None, "Must replace the bundle, not merge old files"
assert metadata.find("scripts/postinstall") is None
payload = component / "Payload"
assert sorted(p.name for p in payload.iterdir()) == ["Applications"]
app = payload / "Applications/Codex 额度提醒.app"
assert sorted(p.name for p in (payload / "Applications").iterdir()) == [app.name]
with (app / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
assert info["CFBundleIdentifier"] == "local.benxin.codex-reset-bar"
assert info["CFBundleShortVersionString"] == version
assert info["LSMinimumSystemVersion"] == "14.0"
assert info["CFBundleIconFile"] in ("AppIcon", "AppIcon.icns")
assert (app / "Contents/Resources/AppIcon.icns").read_bytes() == Path("assets/AppIcon.icns").read_bytes()
assert (app / "Contents/Resources/wechat-qr.png").read_bytes() == Path("assets/wechat-qr.png").read_bytes()
scripts = component / "Scripts"
assert sorted(p.name for p in scripts.iterdir()) == ["StopRunningApp", "preinstall"]
assert (scripts / "preinstall").read_bytes() == Path("installer/macos/scripts/preinstall").read_bytes()
with (work / "choices.plist").open("rb") as stream:
    choices = plistlib.load(stream)
app_choice = choices[0]["childItems"][0]
assert app_choice["choiceIdentifier"] == "app" and app_choice["choiceIsSelected"] == 1
print("PKG: current-user-only domain, wizard, license, QR, payload, atomic upgrade and preinstall verified")
PY

app="$work_dir/expanded/CodexResetBar.pkg/Payload/Applications/Codex 额度提醒.app"
helper="$work_dir/expanded/CodexResetBar.pkg/Scripts/StopRunningApp"
codesign --verify --strict "$app"
codesign --verify --strict "$helper"
xcrun lipo "$app/Contents/MacOS/CodexResetBar" -verify_arch arm64 x86_64
xcrun lipo "$helper" -verify_arch arm64 x86_64

hdiutil verify "$image"
mkdir "$work_dir/mount"
hdiutil attach "$image" -readonly -nobrowse -mountpoint "$work_dir/mount" -quiet
mounted=true
cmp "$package" "$work_dir/mount/1. 双击安装.pkg"
cmp LICENSE "$work_dir/mount/LICENSE"
cmp assets/wechat-qr.png "$work_dir/mount/wechat-qr.png"
launcher="$work_dir/mount/2. 安装后双击启动.app"
codesign --verify --strict "$launcher"
xcrun lipo "$launcher/Contents/MacOS/LaunchInstalledApp" -verify_arch arm64 x86_64
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$launcher/Contents/Info.plist")" = AppIcon
printf 'DMG: read-only mount, identical installer, explicit launch entry, universal binaries, icon and notices verified\n'
