#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-reset-bar-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

flags=(-swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)"
       -target "$(uname -m)-apple-macosx14.0"
       -framework AppKit -framework SwiftUI -framework Security)

run_suite() {
  local suite="$1"
  shift
  printf '\nRunning %s…\n' "$suite"
  xcrun swiftc "${flags[@]}" "$@" "Tests/$suite.swift" -o "$work_dir/$suite"
  "$work_dir/$suite"
}

run_suite QuotaTests Sources/Quota.swift
run_suite ReminderRulesTests Sources/Quota.swift Sources/ReminderRules.swift
run_suite TaskActivityTests Sources/TaskActivity.swift
run_suite PhonePushTests Sources/PhonePush.swift
run_suite RepeatingAlarmTests Sources/RepeatingAlarm.swift

settings_sources=(Sources/Quota.swift Sources/ReminderRules.swift Sources/PhonePush.swift
                  Sources/ReminderSettings.swift)
if [[ -f Sources/AppStyle.swift ]]; then
  settings_sources+=(Sources/AppStyle.swift)
fi
run_suite ReminderStoreTests "${settings_sources[@]}"

# Only model declarations are compiled; Monitor and the app entry point never run.
awk '/^@MainActor final class Monitor/ { found = 1; exit } { print } END { if (!found) exit 1 }' \
  Sources/App.swift > "$work_dir/SavedState.swift"
run_suite NodeIntegrationTests Sources/Quota.swift Sources/ReminderRules.swift \
  Sources/PhonePush.swift "$work_dir/SavedState.swift"
printf '\nAll 7 Swift test suites passed.\n'
