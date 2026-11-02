#!/bin/bash
# Real installation is restricted to GitHub-hosted disposable CI machines.
set -euo pipefail
if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted || "$(id -u)" == 0 ]]; then
  printf 'This install test only runs unprivileged on a disposable GitHub-hosted runner.\n' >&2
  exit 1
fi
cd "$(dirname "$0")/.."
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
package="${1:-dist/CodexResetBar-$version-macOS-universal.pkg}"
app="$HOME/Applications/Codex 额度提醒.app"
test ! -e "$app"
printf 'Testing user-home installation as uid %s (without sudo)…\n' "$(id -u)"
/usr/sbin/installer -pkg "$package" -target CurrentUserHomeDirectory
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version"
codesign --verify --strict "$app"
xcrun lipo "$app/Contents/MacOS/CodexResetBar" -verify_arch arm64 x86_64
test -f "$app/Contents/Resources/AppIcon.icns"

# These synthetic user files must survive a subsequent installation unchanged.
python3 - <<'PY'
from pathlib import Path
import plistlib

home = Path.home()
state = home / "Library/Application Support/CodexResetBar/installer-ci-sentinel"
prefs = home / "Library/Preferences/local.benxin.codex-reset-bar.plist"
login = home / "Library/LaunchAgents/local.benxin.codex-reset-bar.plist"
for path in (state, prefs, login):
    assert not path.exists(), f"Disposable CI runner unexpectedly already has {path}"
    path.parent.mkdir(parents=True, exist_ok=True)
state.write_text("existing user state\n")
prefs.write_bytes(plistlib.dumps({"installerCITest": "preserve", "popup": False}))
login.write_bytes(plistlib.dumps({"Label": "local.benxin.codex-reset-bar",
                                 "ProgramArguments": ["/old/path/CodexResetBar"],
                                 "RunAtLoad": False, "Disabled": True}))
app = home / "Applications/Codex 额度提醒.app"
(app / "obsolete-file-from-previous-bundle").write_text("Remove this during atomic replacement")
PY
/usr/sbin/installer -pkg "$package" -target CurrentUserHomeDirectory
python3 - <<'PY'
from pathlib import Path
import plistlib

home = Path.home()
state = home / "Library/Application Support/CodexResetBar/installer-ci-sentinel"
prefs = home / "Library/Preferences/local.benxin.codex-reset-bar.plist"
login = home / "Library/LaunchAgents/local.benxin.codex-reset-bar.plist"
assert state.read_text() == "existing user state\n"
assert plistlib.loads(prefs.read_bytes()) == {"installerCITest": "preserve", "popup": False}
assert plistlib.loads(login.read_bytes()) == {
    "Label": "local.benxin.codex-reset-bar", "ProgramArguments": ["/old/path/CodexResetBar"],
    "RunAtLoad": False, "Disabled": True,
}
assert not (home / "Applications/Codex 额度提醒.app/obsolete-file-from-previous-bundle").exists()
PY
codesign --verify --strict "$app"
if pgrep -u "$(id -u)" -x CodexResetBar >/dev/null; then
  printf 'Installer must not automatically launch the app.\n' >&2
  exit 1
fi
printf 'CI installation passed: user-home app, valid signature, universal binary, atomic replacement, preserved user state and no automatic launch.\n'
