#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

signing_mode="${CODEX_SIGNING_MODE:-adhoc}"
case "$signing_mode" in
  adhoc|local) ;;
  *) printf 'CODEX_SIGNING_MODE must be adhoc or local.\n' >&2; exit 1 ;;
esac

for required in Info.plist assets/AppIcon.icns assets/app-icon.png assets/wechat-qr.png LICENSE README.md COMMERCIAL.md; do
  if [[ ! -f "$required" ]]; then
    printf 'Missing packaging input: %s\n' "$required" >&2
    exit 1
  fi
done

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$minimum" != "14.0" ]]; then
  printf 'Info.plist must contain a semantic version and macOS minimum 14.0.\n' >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-reset-bar-package.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
app="$work_dir/payload/Applications/Codex 额度提醒.app"
stage="$work_dir/dmg"
launcher="$stage/2. 安装后双击启动.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$launcher/Contents/MacOS" \
  "$launcher/Contents/Resources" "$work_dir/packages" "$work_dir/scripts" dist
sdk="$(xcrun --sdk macosx --show-sdk-path)"

for arch in arm64 x86_64; do
  printf 'Compiling macOS 14+ (%s)…\n' "$arch"
  xcrun swiftc -swift-version 5 -O -sdk "$sdk" -target "$arch-apple-macosx14.0" \
    -framework AppKit -framework SwiftUI -framework Security \
    Sources/*.swift -o "$work_dir/CodexResetBar-$arch"
  xcrun swiftc -swift-version 5 -O -sdk "$sdk" -target "$arch-apple-macosx14.0" \
    -framework AppKit installer/macos/StopRunningApp.swift -o "$work_dir/StopRunningApp-$arch"
  xcrun swiftc -swift-version 5 -O -sdk "$sdk" -target "$arch-apple-macosx14.0" \
    -framework AppKit installer/macos/LaunchInstalledApp.swift -o "$work_dir/LaunchInstalledApp-$arch"
done
xcrun lipo -create "$work_dir/CodexResetBar-arm64" "$work_dir/CodexResetBar-x86_64" \
  -output "$app/Contents/MacOS/CodexResetBar"
xcrun lipo "$app/Contents/MacOS/CodexResetBar" -verify_arch arm64 x86_64
cp Info.plist "$app/Contents/Info.plist"
cp assets/AppIcon.icns assets/wechat-qr.png "$app/Contents/Resources/"
test -f "$app/Contents/Resources/wechat-qr.png"
test -f "$app/Contents/Resources/AppIcon.icns"

if [[ "$signing_mode" == local ]]; then
  python3 scripts/sign-local.py "$app"
else
  codesign --force --sign - --timestamp=none "$app"
fi
codesign --verify --strict "$app"

cp installer/macos/scripts/preinstall "$work_dir/scripts/preinstall"
chmod 755 "$work_dir/scripts/preinstall"
xcrun lipo -create "$work_dir/StopRunningApp-arm64" "$work_dir/StopRunningApp-x86_64" \
  -output "$work_dir/scripts/StopRunningApp"
codesign --force --sign - --timestamp=none "$work_dir/scripts/StopRunningApp"
codesign --verify --strict "$work_dir/scripts/StopRunningApp"

cp -R installer/macos/resources "$work_dir/resources"
cp LICENSE "$work_dir/resources/license.txt"
cp assets/wechat-qr.png assets/app-icon.png "$work_dir/resources/"
sed -e "s/@VERSION@/$version/g" -e "s/@MINIMUM@/$minimum/g" \
  installer/macos/Distribution.xml.in > "$work_dir/Distribution"
pkgbuild --root "$work_dir/payload" --component-plist installer/macos/components.plist \
  --scripts "$work_dir/scripts" --identifier local.benxin.codex-reset-bar.pkg \
  --version "$version" --install-location / --ownership recommended \
  "$work_dir/packages/CodexResetBar.pkg"
package_name="CodexResetBar-$version-macOS-universal.pkg"
productbuild --distribution "$work_dir/Distribution" --resources "$work_dir/resources" \
  --package-path "$work_dir/packages" --identifier local.benxin.codex-reset-bar \
  --version "$version" "$work_dir/product.pkg"
# productbuild may omit images referenced only from HTML. Retain them explicitly
# in this unsigned product archive; do not expand or alter the signed app payload.
pkgutil --expand "$work_dir/product.pkg" "$work_dir/product-expanded"
cp assets/wechat-qr.png assets/app-icon.png "$work_dir/product-expanded/Resources/"
pkgutil --flatten "$work_dir/product-expanded" "$work_dir/$package_name"
cp "$work_dir/$package_name" "$stage/1. 双击安装.pkg"

xcrun lipo -create "$work_dir/LaunchInstalledApp-arm64" "$work_dir/LaunchInstalledApp-x86_64" \
  -output "$launcher/Contents/MacOS/LaunchInstalledApp"
cp assets/AppIcon.icns "$launcher/Contents/Resources/AppIcon.icns"
cat > "$launcher/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.benxin.codex-reset-bar.launcher</string>
  <key>CFBundleName</key><string>启动 Codex 额度提醒</string>
  <key>CFBundleExecutable</key><string>LaunchInstalledApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>$minimum</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$launcher"
codesign --verify --strict "$launcher"

for document in LICENSE README.md COMMERCIAL.md; do
  cp "$document" "$stage/"
done
cp assets/wechat-qr.png "$stage/wechat-qr.png"
mkdir -p "$stage/assets"
cp assets/wechat-qr.png "$stage/assets/"
cat > "$stage/联系方式.txt" <<'CONTACT'
Codex 额度提醒

仅供个人使用。商业使用请先联系作者取得授权，详见 LICENSE 和 COMMERCIAL.md。
微信：wubenxincom
二维码：wechat-qr.png

安装：双击「1. 双击安装.pkg」，跟随向导继续、同意许可并安装。
安装位置：~/Applications/Codex 额度提醒.app（当前用户，无需管理员密码）。
安装完成后：双击「2. 安装后双击启动.app」。
以后启动：Finder 按 Shift-Command-G，输入 ~/Applications，再打开「Codex 额度提醒」。
更新会退出本应用后再替换，保留已有数据、偏好、钥匙串和登录启动设置。
本安装包未经过 Apple 公证，系统可能显示来源提示。
CONTACT

image_name="CodexResetBar-$version-macOS-universal.dmg"
hdiutil create -volname 'Codex 额度提醒' -srcfolder "$stage" -fs HFS+ \
  -format UDZO "$work_dir/$image_name"
hdiutil verify "$work_dir/$image_name"
mv -f "$work_dir/$image_name" "dist/$image_name"
mv -f "$work_dir/$package_name" "dist/$package_name"
(
  cd dist
  shasum -a 256 "$image_name" > "$image_name.sha256"
  shasum -a 256 "$package_name" > "$package_name.sha256"
)
printf 'Built: %s/dist/%s\n       %s/dist/%s\nSigning: %s\n' "$PWD" "$image_name" "$PWD" "$package_name" "$signing_mode"
