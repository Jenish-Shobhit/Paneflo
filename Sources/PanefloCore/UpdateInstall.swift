import Foundation

/// The parts of installing an update that don't need the running app. The app downloads and unzips the
/// release, checks its code signature against its own (`UpdateVerifier`), and hands the swap to `helperScript`.
public enum UpdateInstall {
    /// What the zip holds, at its top level (`ditto -c -k --keepParent Paneflo.app`).
    public static let appName = "Paneflo.app"

    /// Refuses a downloaded bundle whose `Info.plist` (`info`, nil when it couldn't be read) isn't Paneflo's
    /// (`bundleID`) at `expectedVersion` exactly.
    public static func checkBundleInfo(_ info: [String: Any]?, bundleID: String, expectedVersion: String) throws {
        let id = info?["CFBundleIdentifier"] as? String
        guard id == bundleID else { throw UpdateError.wrongBundle(id) }
        let found = info?["CFBundleShortVersionString"] as? String
        guard let found, let a = SemanticVersion(found), let b = SemanticVersion(expectedVersion), a == b else {
            throw UpdateError.wrongVersion(found: found, expected: expectedVersion)
        }
    }

    /// Refuses to replace a copy that isn't a bundle (a bare `swift run`) or that macOS is running from a translocated,
    /// read-only copy (a quarantined download opened where it was unzipped). Whether its folder can be written is the
    /// app's check (`FileManager`), which comes after this one.
    public static func checkLocation(bundlePath: String) throws {
        guard bundlePath.hasSuffix(".app") else { throw UpdateError.notAnApp }
        if bundlePath.contains("/AppTranslocation/") { throw UpdateError.translocated }
    }

    /// The old copy's name in the Trash: `Paneflo 0.0.19` (the helper adds ` 2`, ` 3`… beside an earlier one, and
    /// `.app`). Slashes and colons, which a path can't hold, become dashes.
    public static func trashName(oldVersion: String) -> String {
        let safe = oldVersion.map { $0 == "/" || $0 == ":" ? "-" : $0 }
        return "Paneflo " + String(safe)
    }

    /// The most a download may be, in bytes: the size GitHub lists for the asset (it's exact), or, without one, far more
    /// than Paneflo will ever be. A download that goes past it stops at once instead of filling the disk.
    public static func downloadLimit(listedSize: Int) -> Int64 {
        listedSize > 0 ? Int64(listedSize) : 512 << 20
    }

    /// How long the helper waits for Paneflo to quit before it gives up and changes nothing, in tenths of a second.
    /// Quitting stops the event taps and the capture streams within a second or two; this leaves ample room.
    public static let quitWaitTenths = 300

    /// The detached helper, run as `/bin/sh -c helperScript paneflo-update <arguments>` (see `helperArguments`). It
    /// survives Paneflo's exit and:
    /// 1. waits for Paneflo's process to exit (at most `quitWaitTenths`; otherwise it changes nothing);
    /// 2. moves the old app into the Trash folder as `<name>.app` (`<name> 2.app`… beside an earlier one): with
    ///    `mv`, since `NSWorkspace.recycle` can't run once Paneflo has quit, so Finder's Put Back doesn't know it;
    /// 3. moves the new app into the old one's place (a rename: the new app waits on the same volume), putting the old
    ///    one back if that fails;
    /// 4. removes any quarantine attribute and opens the app at that path, the new one or, after a failure, the old one,
    ///    in the background (`open -g`): the app the user is in keeps the keyboard, as it did when Paneflo quit;
    /// 5. deletes the staging folder (the zip and what's left of it).
    /// Each step is appended to the log file, and a failure starts with `FAILED:`.
    public static let helperScript = #"""
        app=$1; new=$2; staging=$3; pid=$4; trash=$5; name=$6; log=$7; open=$8; limit=$9
        note() { printf '%s  %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$log"; }
        cleanup() { case "$staging" in /?*/?*) /bin/rm -rf "$staging" ;; esac; }
        note "Waiting for Paneflo (pid $pid) to quit"
        i=0
        while /bin/kill -0 "$pid" 2>/dev/null; do
          if [ "$i" -ge "$limit" ]; then note "FAILED: Paneflo didn't quit, so nothing was changed"; cleanup; exit 1; fi
          /bin/sleep 0.1; i=$((i + 1))
        done
        if [ ! -d "$new" ]; then
          note "FAILED: the new app is missing ($new), so nothing was changed"; cleanup; "$open" -g "$app"; exit 1
        fi
        /bin/mkdir -p "$trash"
        dest="$trash/$name.app"; n=2
        while [ -e "$dest" ]; do dest="$trash/$name $n.app"; n=$((n + 1)); done
        if ! /bin/mv "$app" "$dest"; then
          note "FAILED: couldn't move $app to the Trash, so nothing was changed"; cleanup; "$open" -g "$app"; exit 1
        fi
        if [ -e "$app" ] || ! /bin/mv "$new" "$app"; then
          note "FAILED: couldn't put the new app at $app; the old one is back"
          [ -e "$app" ] || /bin/mv "$dest" "$app"
          cleanup; "$open" -g "$app"; exit 1
        fi
        /usr/bin/xattr -r -d com.apple.quarantine "$app" 2>/dev/null
        note "Installed $app; the previous copy is in the Trash as ${dest##*/}"
        cleanup
        "$open" -g "$app"
        exit 0
        """#

    /// The arguments after `-c helperScript` (`$0` is a name for `ps`). `open` is `/usr/bin/open` but for tests.
    public static func helperArguments(app: URL, newApp: URL, staging: URL, pid: Int32, trash: URL, trashName: String,
                                       log: URL, open: String = "/usr/bin/open",
                                       quitWaitTenths: Int = quitWaitTenths) -> [String] {
        ["-c", helperScript, "paneflo-update", app.path, newApp.path, staging.path, String(pid), trash.path, trashName,
         log.path, open, String(quitWaitTenths)]
    }

    /// The helper's log: `~/Library/Logs/Paneflo/Update.log`.
    public static var logFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Paneflo/Update.log")
    }

    /// The last thing the helper logged after `since` that says it failed, without its timestamp: what the next launch
    /// reports when it isn't the new version. Nil when there's none.
    public static func lastFailure(inLog log: String, since: Date) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var found: String?
        for line in log.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let date = formatter.date(from: parts[0] + " " + parts[1]),
                  date >= since.addingTimeInterval(-1) else { continue }
            let text = parts[2].trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("FAILED: ") { found = String(text.dropFirst("FAILED: ".count)) }
        }
        return found
    }
}
