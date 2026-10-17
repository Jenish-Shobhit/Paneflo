import AppKit
import Observation
import os
import PanefloCore

/// Updates from GitHub: the checks, the update window's state, and installing a release.
///
/// - **Checks** ask GitHub's public API for the latest release, and nothing else: automatically (the "Check for
///   updates automatically" setting, on by default) at most once a day, never while a switcher or overview session is
///   showing; and when asked (Check for Updates…). With the setting off and nothing asked, Paneflo makes no request.
/// - **The window** offers a newer release with its notes: Install and Relaunch, Later, Skip This Version. A check the
///   user asked for also says when Paneflo is up to date, and what went wrong.
/// - **Installing** downloads `Paneflo-<version>.zip`, unzips and checks it (`UpdateVerifier`: the same bundle ID signed
///   by the same certificate as this copy), and hands the swap to a detached helper (`UpdateInstall.helperScript`) that
///   waits for Paneflo to quit. The next launch says how it went.
@MainActor @Observable
final class UpdateController {
    static let shared = UpdateController()
    nonisolated static let log = Logger(subsystem: "dev.paneflo.Paneflo", category: "updates")

    enum Phase: Equatable {
        case idle
        /// A check the user asked for is running.
        case checking
        /// A check the user asked for found nothing newer.
        case upToDate
        case available(AvailableUpdate)
        /// `fraction` is nil until the size is known.
        case downloading(AvailableUpdate, fraction: Double?, received: Int64, total: Int64)
        case verifying(AvailableUpdate)
        /// Verified: the helper is waiting for Paneflo to quit.
        case relaunching(AvailableUpdate)
        /// `update` is the release being installed, or nil when the check failed.
        case failed(UpdateError, update: AvailableUpdate?)

        var update: AvailableUpdate? {
            switch self {
            case .available(let u), .downloading(let u, _, _, _), .verifying(let u), .relaunching(let u): u
            case .failed(_, let u): u
            case .idle, .checking, .upToDate: nil
            }
        }

        var isInstalling: Bool {
            switch self {
            case .downloading, .verifying, .relaunching: true
            default: false
            }
        }
    }

    private(set) var phase: Phase = .idle

    nonisolated static var currentVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    let currentVersion = SemanticVersion(UpdateController.currentVersionString) ?? SemanticVersion(major: 0, minor: 0, patch: 0)

    /// How long after launch the first automatic check waits, so it never competes with startup work.
    static let launchDelay: Duration = .seconds(10)
    /// How often the running app looks at whether a check is due (`UpdateSchedule`).
    static let pollInterval: TimeInterval = 60 * 60

    @ObservationIgnored private let settings = UpdateSettings()
    @ObservationIgnored private var started = false
    /// A check was asked for before `start`.
    @ObservationIgnored private var checkAskedBeforeStart = false
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    /// The running check shows its result: a manual check, or an automatic one the user asked for while it ran.
    @ObservationIgnored private var checkIsManual = false
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var staging: URL?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastProgressUpdate = Date.distantPast

    /// True while a switcher or overview session is showing: an automatic check waits for it to end, and an automatic
    /// offer is held until it has (the update window would be in the way). Set it before or in `start`.
    @ObservationIgnored var isBusy: () -> Bool = { false }
    /// Shows a one-line message after a relaunch ("Updated to Paneflo 0.1.2").
    @ObservationIgnored var report: (String) -> Void = { _ in }

    /// The "Check for updates automatically" setting.
    var checksAutomatically: Bool {
        get { access(keyPath: \.checksAutomatically); return settings.checksAutomatically }
        set { withMutation(keyPath: \.checksAutomatically) { settings.checksAutomatically = newValue } }
    }

    // MARK: - Lifecycle

    /// Called once at launch, after everything else is wired: reports how an update installed before this launch went,
    /// runs a check asked for meanwhile, and starts the automatic checks.
    func start(isBusy: @escaping () -> Bool, report: @escaping (String) -> Void) {
        guard !started else { return }
        started = true
        self.isBusy = isBusy
        self.report = report
        reportInstalledUpdate()
        if checkAskedBeforeStart {
            checkAskedBeforeStart = false
            checkForUpdates()
        }
        Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: Self.launchDelay)
            self?.automaticCheck(atLaunch: true)
        }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.automaticCheck(atLaunch: false) }
        }
        timer.tolerance = 10 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Checking

    /// Check for Updates…: checks now (a skipped version too) and shows the result.
    func checkForUpdates() {
        guard started else {
            checkAskedBeforeStart = true
            return
        }
        if phase.isInstalling {
            showWindow(activate: true)
            return
        }
        phase = .checking
        showWindow(activate: true)
        if checkTask != nil {
            checkIsManual = true // the automatic check already running answers this one
            return
        }
        runCheck(manual: true)
    }

    /// At launch and every hour: checks when the setting is on and one is due, unless the update window is open (it shows
    /// something the user hasn't answered yet, a failed install's report among them) or a switcher or overview session is
    /// showing (then a minute later).
    private func automaticCheck(atLaunch: Bool) {
        guard settings.checksAutomatically, checkTask == nil, installTask == nil,
              !UpdateWindowController.shared.isVisible, !phase.isInstalling else { return }
        guard UpdateSchedule.isDue(lastCheck: settings.lastCheck, now: Date(), atLaunch: atLaunch) else { return }
        if isBusy() {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                self?.automaticCheck(atLaunch: atLaunch)
            }
            return
        }
        runCheck(manual: false)
    }

    private func runCheck(manual: Bool) {
        checkIsManual = manual
        Self.log.notice("Checking for updates (\(manual ? "asked" : "automatic", privacy: .public))")
        checkTask = Task(priority: manual ? .userInitiated : .utility) { [weak self] in
            let result: Result<GitHubRelease, UpdateError>
            do {
                result = .success(try await UpdateNetwork.latestRelease(from: UpdateCheck.latestReleaseURL))
            } catch is CancellationError {
                return
            } catch let error as UpdateError {
                result = .failure(error)
            } catch {
                result = .failure(.offline(error.localizedDescription))
            }
            self?.checkFinished(result)
        }
    }

    private func checkFinished(_ result: Result<GitHubRelease, UpdateError>) {
        checkTask = nil
        let manual = checkIsManual
        checkIsManual = false
        // The window may have moved on meanwhile (Cancel, or an install started from an earlier answer).
        if manual, phase != .checking { return }
        if !manual, phase.isInstalling { return }
        let decision: UpdateDecision
        do {
            let release = try result.get()
            settings.lastCheck = Date()
            decision = try UpdateCheck.decide(release, current: currentVersion, skipped: settings.skippedVersion,
                                              manual: manual)
        } catch {
            let error = error as? UpdateError ?? .unreadableAnswer
            Self.log.error("Update check failed: \(error.message, privacy: .public)")
            if manual { phase = .failed(error, update: nil) }
            return
        }
        switch decision {
        case .available(let update):
            Self.log.notice("Paneflo \(update.versionString, privacy: .public) is available")
            phase = .available(update)
            if manual { showWindow(activate: true) } else { showOfferWhenIdle() }
        case .upToDate:
            Self.log.notice("Paneflo \(self.currentVersion.description, privacy: .public) is up to date")
            if manual { phase = .upToDate }
        case .skipped(let version):
            Self.log.notice("Paneflo \(version, privacy: .public) is available, but skipped")
        }
    }

    /// An automatic check's offer, once no session is showing: one may have started while it asked, and the window would
    /// be in front of it. Nothing, if the offer was answered meanwhile (a manual check, Later).
    private func showOfferWhenIdle() {
        guard case .available = phase else { return }
        guard !isBusy() else {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.showOfferWhenIdle()
            }
            return
        }
        showWindow(activate: false)
    }

    // MARK: - The window's buttons

    /// Install and Relaunch.
    func install() {
        guard installTask == nil, let update = phase.update else { return }
        let app = Bundle.main.bundleURL.standardizedFileURL
        do {
            try UpdateInstall.checkLocation(bundlePath: app.path)
            let folder = app.deletingLastPathComponent()
            let fm = FileManager.default
            guard fm.isWritableFile(atPath: folder.path), fm.isWritableFile(atPath: app.path) else {
                throw UpdateError.folderNotWritable(folder.path)
            }
            guard UpdateVerifier.runningCopyIsSigned else { throw UpdateError.runningCopyUnsigned }
        } catch {
            fail(error, update)
            return
        }
        Self.log.notice("Installing Paneflo \(update.versionString, privacy: .public) over \(app.path, privacy: .public)")
        phase = .downloading(update, fraction: nil, received: 0, total: Int64(update.asset.size))
        installTask = Task { [weak self] in await self?.runInstall(update, app: app) }
    }

    private func runInstall(_ update: AvailableUpdate, app: URL) async {
        do {
            // On the app's own volume, so the helper's last step is a rename.
            let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                      appropriateFor: app, create: true)
            self.staging = staging
            let zip = staging.appendingPathComponent(update.asset.name)
            let expected = Int64(update.asset.size)
            let limit = UpdateInstall.downloadLimit(listedSize: update.asset.size)
            try await UpdateNetwork.download(update.asset.downloadURL, to: zip, limit: limit) { [weak self] received, total in
                Task { @MainActor in self?.downloaded(received, of: total > 0 ? total : expected) }
            }
            try Task.checkCancellation()
            phase = .verifying(update)
            let asset = update.asset, version = update.versionString
            let newApp = try await Task.detached(priority: .userInitiated) {
                try UpdateVerifier.checkDownload(zip, asset: asset)
                let app = try UpdateVerifier.unzip(zip, into: staging.appendingPathComponent("extracted", isDirectory: true))
                try UpdateVerifier.verify(app, expectedVersion: version)
                return app
            }.value
            try Task.checkCancellation()
            phase = .relaunching(update)
            try launchHelper(app: app, newApp: newApp, staging: staging)
            settings.pendingUpdate = (update.versionString, Date())
            installTask = nil
            Self.log.notice("Paneflo \(update.versionString, privacy: .public) verified; quitting so the helper can install it")
            quit()
            // Quitting never takes this long: still here, Paneflo didn't quit, and the helper has given up.
            try? await Task.sleep(for: .seconds(Double(UpdateInstall.quitWaitTenths) / 10 + 5))
            if case .relaunching = phase {
                settings.pendingUpdate = nil
                fail(UpdateError.helperFailed(version: update.versionString, detail: "Paneflo didn’t quit"), update)
            }
        } catch is CancellationError {
            removeStaging()
            installTask = nil
            if phase.isInstalling { phase = .available(update) }
        } catch {
            removeStaging()
            installTask = nil
            fail(error, update)
        }
    }

    private func downloaded(_ received: Int64, of total: Int64) {
        guard case .downloading(let update, _, _, _) = phase else { return }
        // A few redraws a second is plenty.
        let now = Date()
        guard received >= total || now.timeIntervalSince(lastProgressUpdate) > 0.1 else { return }
        lastProgressUpdate = now
        let fraction = total > 0 ? min(1, Double(received) / Double(total)) : nil
        phase = .downloading(update, fraction: fraction, received: received, total: total)
    }

    /// Starts the detached helper (`/bin/sh`), which outlives Paneflo: it waits for this process to exit, puts the new app
    /// in place of `app` (the old one goes to the Trash), and opens it.
    private func launchHelper(app: URL, newApp: URL, staging: URL) throws {
        let fm = FileManager.default
        let trash: URL
        do {
            trash = try fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        } catch {
            trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        }
        let log = UpdateInstall.logFile
        try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = UpdateInstall.helperArguments(
            app: app, newApp: newApp, staging: staging, pid: ProcessInfo.processInfo.processIdentifier, trash: trash,
            trashName: UpdateInstall.trashName(oldVersion: Self.currentVersionString), log: log)
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            throw UpdateError.helper(error.localizedDescription)
        }
        self.staging = nil // the helper deletes it now
    }

    /// Later (and closing the window): stops a download, and the next automatic check offers it again.
    func later() {
        cancelInstall()
        phase = .idle
        UpdateWindowController.shared.close()
    }

    /// Skip This Version: automatic checks don't offer this version again.
    func skip() {
        if let update = phase.update {
            settings.skippedVersion = update.versionString
            Self.log.notice("Skipping Paneflo \(update.versionString, privacy: .public)")
        }
        later()
    }

    /// Cancel, while checking or downloading.
    func cancel() {
        switch phase {
        case .checking:
            checkIsManual = false
            checkTask?.cancel()
            checkTask = nil
            phase = .idle
            UpdateWindowController.shared.close()
        case .downloading, .verifying:
            cancelInstall()
        default:
            later()
        }
    }

    /// The window closed (its close button, ⌘W): as Later, except once the helper is waiting.
    func windowClosed() {
        if case .relaunching = phase { return }
        if case .checking = phase { cancel(); return }
        cancelInstall()
        phase = .idle
    }

    private func cancelInstall() {
        if case .relaunching = phase { return }
        installTask?.cancel()
    }

    /// From the run loop, not from this main-actor task: terminating may run delegate work that can't happen inside the
    /// block that is waiting for it.
    private func quit() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(phase.update?.releasePage ?? UpdateCheck.releasesPage)
    }

    private func fail(_ error: any Error, _ update: AvailableUpdate?) {
        let error = error as? UpdateError ?? .download(error.localizedDescription)
        Self.log.error("Update failed: \(error.message, privacy: .public)")
        phase = .failed(error, update: update)
        showWindow(activate: true)
        // The way out is installing by hand.
        if error.opensReleasesPage { openReleasesPage() }
    }

    private func removeStaging() {
        guard let staging else { return }
        self.staging = nil
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: staging) }
    }

    private func showWindow(activate: Bool) {
        UpdateWindowController.shared.show(activate: activate)
    }

    // MARK: - After the relaunch

    /// The launch after Install and Relaunch: "Updated to Paneflo X", or the window with what went wrong (the helper
    /// reopens the old copy when it couldn't install the new one).
    private func reportInstalledUpdate() {
        guard let pending = settings.pendingUpdate else { return }
        settings.pendingUpdate = nil
        // A day later it's old news (the helper never got to relaunch, and the user opened Paneflo themselves).
        guard Date().timeIntervalSince(pending.date) < 24 * 60 * 60 else { return }
        if UpdateCheck.isSameVersion(pending.version, Self.currentVersionString) {
            Self.log.notice("Updated to Paneflo \(pending.version, privacy: .public)")
            report("Updated to Paneflo \(pending.version).")
            return
        }
        let detail = (try? String(contentsOf: UpdateInstall.logFile, encoding: .utf8))
            .flatMap { UpdateInstall.lastFailure(inLog: $0, since: pending.date) }
        Self.log.error("Paneflo \(pending.version, privacy: .public) wasn't installed: \(detail ?? "no reason logged", privacy: .public)")
        phase = .failed(.helperFailed(version: pending.version, detail: detail), update: nil)
        showWindow(activate: true)
    }
}
