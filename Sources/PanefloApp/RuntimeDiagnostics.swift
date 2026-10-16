import Foundation

/// Explicit, title-free startup tracing for local launch troubleshooting.
/// Disabled in normal use; callers choose where stderr is stored.
enum RuntimeDiagnostics {
    static let isEnabled = CommandLine.arguments.contains("--diagnostics")

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
