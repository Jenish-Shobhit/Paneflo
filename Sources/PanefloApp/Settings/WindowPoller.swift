import AppKit

/// A once-a-second tick that runs only while its window is visible: started on show, stopped when the window closes or
/// the app hides, resumed on unhide if the window is still up. Settings and the setup window use it to keep permission
/// rows live without doing anything while they are closed.
@MainActor
final class WindowPoller {
    var interval: TimeInterval = 1
    var onTick: (() -> Void)?
    private let isVisible: () -> Bool
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    var isRunning: Bool { timer != nil }

    init(isVisible: @escaping () -> Bool) {
        self.isVisible = isVisible
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didUnhideNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, self.isVisible() { self.start() } }
        })
    }

    isolated deinit {
        timer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible() else { return }
                self.onTick?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
