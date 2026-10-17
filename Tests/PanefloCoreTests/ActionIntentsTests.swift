import Testing
@testable import PanefloCore

/// Release-to-focus must not wait for placement: the two actions never invalidate each other.
struct ActionIntentsTests {
    private func id(_ number: UInt32) -> WindowIdentity {
        .init(process: .init(pid: 42, launchToken: 8), number: number, incarnation: 1)
    }

    @Test func focusIssuedAfterATileDoesNotCancelThePendingPlacement() {
        var intents = ActionIntents()
        let tile = intents.beginPlacement(for: id(1))
        let focus = intents.beginFocus() // release, with the tile still in flight
        #expect(intents.isCurrentPlacement(tile, for: id(1)))
        #expect(intents.isCurrentFocus(focus))
    }

    @Test func tileIssuedAfterFocusDoesNotCancelFocus() {
        var intents = ActionIntents()
        let focus = intents.beginFocus()
        _ = intents.beginPlacement(for: id(1))
        #expect(intents.isCurrentFocus(focus))
    }

    @Test func aNewerFocusSupersedesOnlyOlderFocus() {
        var intents = ActionIntents()
        let first = intents.beginFocus()
        let second = intents.beginFocus()
        #expect(!intents.isCurrentFocus(first))
        #expect(intents.isCurrentFocus(second))
    }

    @Test func placementIsSupersededOnlyByANewerPlacementOfTheSameWindow() {
        var intents = ActionIntents()
        let first = intents.beginPlacement(for: id(1))
        let other = intents.beginPlacement(for: id(2))
        #expect(intents.isCurrentPlacement(first, for: id(1)))
        let second = intents.beginPlacement(for: id(1))
        #expect(!intents.isCurrentPlacement(first, for: id(1)))
        #expect(intents.isCurrentPlacement(second, for: id(1)))
        #expect(intents.isCurrentPlacement(other, for: id(2)))
    }

    @Test func forgottenWindowsHaveNoCurrentPlacement() {
        var intents = ActionIntents()
        let token = intents.beginPlacement(for: id(1))
        intents.forget(id(1))
        #expect(!intents.isCurrentPlacement(token, for: id(1)))
    }
}
