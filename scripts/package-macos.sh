#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

signing_mode="${CODEX_SIGNING_MODE:-adhoc}"
case "$signing_mode" in
  adhoc|local) ;;
  *) printf 'CODEX_SIGNING_MODE must be adhoc or local.\n' >&2; exit 1 ;;
esac

for required in Info.plist assets/wechat-qr.png LICENSE README.md COMMERCIAL.md; do
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
app="$work_dir/staging/Codex 额度提醒.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" dist
sdk="$(xcrun --sdk macosx --show-sdk-path)"

for arch in arm64 x86_64; do
  printf 'Compiling macOS 14+ (%s)…\n' "$arch"
  xcrun swiftc -swift-version 5 -O -sdk "$sdk" -target "$arch-apple-macosx14.0" \
    -framework AppKit -framework SwiftUI -framework Security \
    Sources/*.swift -o "$work_dir/CodexResetBar-$arch"
done
xcrun lipo -create "$work_dir/CodexResetBar-arm64" "$work_dir/CodexResetBar-x86_64" \
  -output "$app/Contents/MacOS/CodexResetBar"
xcrun lipo "$app/Contents/MacOS/CodexResetBar" -verify_arch arm64 x86_64
cp Info.plist "$app/Contents/Info.plist"
cp -R assets/. "$app/Contents/Resources/"
test -f "$app/Contents/Resources/wechat-qr.png"

if [[ "$signing_mode" == local ]]; then
  python3 scripts/sign-local.py "$app"
else
  codesign --force --sign - --timestamp=none "$app"
fi
codesign --verify --strict "$app"

stage="$work_dir/staging"
ln -s /Applications "$stage/Applications"
for document in LICENSE README.md COMMERCIAL.md; do
  cp "$document" "$stage/"
done
cp assets/wechat-qr.png "$stage/wechat-qr.png"
mkdir -p "$stage/assets"
cp -R assets/. "$stage/assets/"
cat > "$stage/联系方式.txt" <<'CONTACT'
Codex 额度提醒

仅供个人使用。商业使用请先联系作者取得授权，详见 LICENSE 和 COMMERCIAL.md。
微信：wubenxincom
二维码：wechat-qr.png

安装：将「Codex 额度提醒.app」拖入 Applications。
CONTACT

image_name="CodexResetBar-$version-macOS-universal.dmg"
hdiutil create -volname 'Codex 额度提醒' -srcfolder "$stage" -fs HFS+ \
  -format UDZO "$work_dir/$image_name"
hdiutil verify "$work_dir/$image_name"
mv -f "$work_dir/$image_name" "dist/$image_name"
(
  cd dist
  shasum -a 256 "$image_name" > "$image_name.sha256"
)
printf 'Built: %s/dist/%s\nSigning: %s\n' "$PWD" "$image_name" "$signing_mode"
