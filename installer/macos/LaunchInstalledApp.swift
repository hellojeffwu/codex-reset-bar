import AppKit

let target = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Applications/Codex 额度提醒.app")
NSApplication.shared.setActivationPolicy(.accessory)
guard FileManager.default.fileExists(atPath: target.path),
      Bundle(url: target)?.bundleIdentifier == "local.benxin.codex-reset-bar" else {
    let alert = NSAlert()
    alert.messageText = "请先完成安装"
    alert.informativeText = "先双击磁盘映像中的“1. 双击安装.pkg”，按照提示完成后，再从这里启动。"
    alert.runModal()
    exit(1)
}
NSWorkspace.shared.openApplication(at: target, configuration: NSWorkspace.OpenConfiguration()) { _, error in
    if let error = error {
        let alert = NSAlert()
        alert.messageText = "暂时无法启动 Codex 额度提醒"
        alert.informativeText = "请在 Finder 中前往 ~/Applications 并打开应用。\n\(error.localizedDescription)"
        alert.runModal()
    }
    NSApp.terminate(nil)
}
NSApp.run()
