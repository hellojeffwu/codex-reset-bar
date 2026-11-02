import AppKit
import Darwin

// Installer runs this helper as the user for CurrentUserHomeDirectory installs.
// Match our bundle and executable, never a generic process name or another app.
guard getuid() != 0 else { exit(1) }
let appID = "local.benxin.codex-reset-bar"
func runningCopies() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: appID).filter { app in
        if app.isTerminated { return false }
        var info = proc_bsdinfo()
        guard proc_pidinfo(app.processIdentifier, PROC_PIDTBSDINFO, 0, &info,
                           Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else {
            if app.isTerminated || (kill(app.processIdentifier, 0) != 0 && errno == ESRCH) { return false }
            fputs("无法确认旧进程身份，请先退出 Codex 额度提醒后再安装。\n", stderr)
            exit(1)
        }
        guard info.pbi_uid == getuid() else { return false }
        guard let bundle = app.bundleURL, let executable = app.executableURL,
              executable.standardizedFileURL == bundle.appendingPathComponent("Contents/MacOS/CodexResetBar").standardizedFileURL,
              Bundle(url: bundle)?.bundleIdentifier == appID else {
            fputs("发现无法安全确认的同标识进程，请先手动退出 Codex 额度提醒后再安装。\n", stderr)
            exit(1)
        }
        return true
    }
}

let apps = runningCopies()
for app in apps { _ = app.terminate() }
let deadline = ProcessInfo.processInfo.systemUptime + 12
while !runningCopies().isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
}
guard runningCopies().isEmpty else {
    fputs("Codex 额度提醒仍在运行。请从菜单栏退出后重新安装；尚未替换应用。\n", stderr)
    exit(1)
}
