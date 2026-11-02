import Foundation

enum LoginConfiguration {
    // Only relocate this app's existing login item; preserve its other settings.
    static func relocated(_ plist: [String: Any], label: String, executable: String) -> [String: Any]? {
        guard plist["Label"] as? String == label,
              var arguments = plist["ProgramArguments"] as? [String],
              let previous = arguments.first,
              URL(fileURLWithPath: previous).lastPathComponent == "CodexResetBar",
              previous != executable else { return nil }
        arguments[0] = executable
        var result = plist
        result["ProgramArguments"] = arguments
        return result
    }
}
