import Foundation

@main struct LoginConfigurationTests {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { fatalError("FAIL: \(message)") }
        }
        let label = "local.benxin.codex-reset-bar"
        let executable = "/Users/test/Applications/Codex 额度提醒.app/Contents/MacOS/CodexResetBar"
        let existing: [String: Any] = ["Label": label,
            "ProgramArguments": ["/Applications/Codex 额度提醒.app/Contents/MacOS/CodexResetBar", "--background"],
            "RunAtLoad": false, "Disabled": true, "ProcessType": "Interactive"]
        let updated = LoginConfiguration.relocated(existing, label: label, executable: executable)!
        expect(updated["ProgramArguments"] as? [String] == [executable, "--background"], "upgrade relocates executable and retains arguments")
        expect(updated["RunAtLoad"] as? Bool == false, "does not enable login startup")
        expect(updated["Disabled"] as? Bool == true, "retains disabled state")
        expect(updated["ProcessType"] as? String == "Interactive", "retains unrelated fields")
        expect(LoginConfiguration.relocated(updated, label: label, executable: executable) == nil, "same path requires no rewrite")
        var other = existing
        other["Label"] = "other.application"
        expect(LoginConfiguration.relocated(other, label: label, executable: executable) == nil, "never changes another app's login item")
        other = existing
        other["ProgramArguments"] = ["/usr/bin/codex"]
        expect(LoginConfiguration.relocated(other, label: label, executable: executable) == nil, "does not rewrite a different executable")
        other["ProgramArguments"] = [] as [String]
        expect(LoginConfiguration.relocated(other, label: label, executable: executable) == nil, "empty command is untouched")
        other["ProgramArguments"] = [12]
        expect(LoginConfiguration.relocated(other, label: label, executable: executable) == nil, "malformed command is untouched")
        expect(LoginConfiguration.relocated([:], label: label, executable: executable) == nil, "missing item does not create or enable login startup")
        print("PASS: \(checks) login configuration checks (isolated data)")
    }
}
