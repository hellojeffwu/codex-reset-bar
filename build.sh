#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p 'build/Codex 额度提醒.app/Contents/MacOS' 'build/Codex 额度提醒.app/Contents/Resources'
xcrun swiftc -swift-version 5 -O -framework AppKit -framework SwiftUI -framework Security Sources/*.swift -o 'build/Codex 额度提醒.app/Contents/MacOS/CodexResetBar'
cp Info.plist 'build/Codex 额度提醒.app/Contents/Info.plist'
cp assets/wechat-qr.png 'build/Codex 额度提醒.app/Contents/Resources/wechat-qr.png'
python3 scripts/sign-local.py 'build/Codex 额度提醒.app'
printf 'Built: %s/build/Codex 额度提醒.app\n' "$PWD"
