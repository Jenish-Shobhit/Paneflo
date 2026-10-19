import Dispatch

/// A one-shot main-queue timer that fires on its deadline. `Task.sleep`, `asyncAfter` and `Timer` let the system
/// coalesce their deadlines; for a process that is not the active app (Paneflo never is while its panels show) a
/// 100 ms wait was measured firing 6–10 ms late and a 16 ms one about 6 ms late on one Mac. This timer uses a strict
/// dispatch source with no leeway (measured within 0.2 ms there). Use it only for short waits that a user is
/// waiting on; a strict timer cannot be coalesced with others, so it costs a little more energy.
@MainActor
public final class PreciseTimer {
    private var source: (any DispatchSourceTimer)?

    public init() {}

    isolated deinit { source?.cancel() }

    public var isScheduled: Bool { source != nil }

    /// Replaces any pending firing. `action` runs on the main queue unless the timer is cancelled or rescheduled first.
    public func schedule(after seconds: Double, _ action: @escaping @MainActor () -> Void) {
        source?.cancel()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + max(0, seconds), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self, weak timer] in
            MainActor.assumeIsolated {
                guard let self, let timer, self.source === timer else { return }
                timer.cancel()
                self.source = nil
                action()
            }
        }
        source = timer
        timer.resume()
    }

    public func cancel() {
        source?.cancel()
        source = nil
    }
}
