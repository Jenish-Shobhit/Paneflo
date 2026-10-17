import Testing
@testable import PanefloCore

struct WindowNumberMatcherTests {
    private let frame = WindowRect(x: 100, y: 80, width: 900, height: 600)

    private func entry(_ number: UInt32, pid: Int32 = 7, frame: WindowRect? = nil, title: String? = nil,
                       layer: Int = 0, stack: Int) -> WindowServerEntry {
        WindowServerEntry(number: number, ownerPID: pid, layer: layer, frame: frame ?? self.frame, title: title, stackIndex: stack)
    }

    @Test func sameSizeSameAppWindowsAreDisambiguatedByStackingOrder() {
        // Two default-positioned windows of one app, identical frames, no window-server titles.
        let entries = [entry(501, stack: 3), entry(400, stack: 1)]
        let probes = [AccessibilityWindowProbe(frame: frame, title: "Front"),
                      AccessibilityWindowProbe(frame: frame, title: "Back")]
        // AX order is front to back; window server stacking puts 400 in front.
        #expect(WindowNumberMatcher.match(pid: 7, probes: probes, entries: entries) == [400, 501])
    }

    @Test func frameTitleAndKnownNumbersResolveBeforeStackingOrder() {
        let moved = WindowRect(x: 300, y: 80, width: 900, height: 600)
        let entries = [entry(10, stack: 0), entry(11, title: "Notes", stack: 1), entry(12, stack: 2),
                       entry(13, frame: moved, stack: 3), entry(14, pid: 8, stack: 4), entry(15, layer: 3, stack: 5)]
        let probes = [AccessibilityWindowProbe(frame: frame, title: "Draft"),
                      AccessibilityWindowProbe(frame: moved, title: "Moved"),
                      AccessibilityWindowProbe(frame: frame, title: "Notes"),
                      AccessibilityWindowProbe(frame: .zero, title: "Direct", known: 12)]
        // 13 by unique frame, 11 by title, 12 directly; 10 then becomes the only candidate left.
        #expect(WindowNumberMatcher.match(pid: 7, probes: probes, entries: entries) == [10, 13, 11, 12])
    }

    @Test func unresolvableAmbiguityStaysNil() {
        let entries = [entry(1, stack: 0), entry(2, stack: 1), entry(3, stack: 2)]
        let probes = [AccessibilityWindowProbe(frame: frame), AccessibilityWindowProbe(frame: frame)]
        #expect(WindowNumberMatcher.match(pid: 7, probes: probes, entries: entries) == [nil, nil])
        // A known number not owned by this process is ignored; claimed numbers are excluded.
        let foreign = [AccessibilityWindowProbe(frame: frame, known: 99)]
        #expect(WindowNumberMatcher.match(pid: 7, probes: foreign, entries: [entry(1, stack: 0), entry(99, pid: 8, stack: 1)]) == [1])
        #expect(WindowNumberMatcher.match(pid: 7, probes: foreign, entries: [entry(1, stack: 0)], claimed: [1]) == [nil])
    }
}
