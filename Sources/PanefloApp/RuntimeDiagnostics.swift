import Foundation

/// Explicit, title-free startup tracing for local launch troubleshooting.
/// Disabled in normal use; callers choose where stderr is stored.
enum RuntimeDiagnostics {
    static let isEnabled = CommandLine.arguments.contains("--diagnostics")

    /// `--bench-no-input`: benchmark launches (scripts/bench.sh launch) only. The process installs no event tap and no
    /// trackpad listener, shows no setup window and runs no update check, so it can run next to the owner's session
    /// without touching input. Never set by the app itself or by a normal launch.
    static let benchNoInput = CommandLine.arguments.contains("--bench-no-input")

    static func mark(_ phase: String) {
        guard isEnabled else { return }
        let line = "Paneflo startup: \(phase)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    static func handleCommandLine() -> Bool {
        if CommandLine.arguments.contains("--version") {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
            print("Paneflo \(version)")
            return true
        }
        return false
    }
}
