import Testing
@testable import PanefloCore

struct DisplayCoordinatesTests {
    @Test func convertsUsablePrimaryFrameWithMenuAndDock() {
        let appKit = WindowRect(x: 0, y: 70, width: 1440, height: 805)
        #expect(DisplayCoordinates.accessibilityFrame(fromAppKit: appKit, primaryHeight: 900) == WindowRect(x: 0, y: 25, width: 1440, height: 805))
    }

    @Test func roundTripsDisplaysAboveAndBelowPrimary() {
        for frame in [WindowRect(x: -1200, y: 900, width: 1200, height: 1600), WindowRect(x: 1440, y: -1200, width: 1920, height: 1200)] {
            let ax = DisplayCoordinates.accessibilityFrame(fromAppKit: frame, primaryHeight: 900)
            #expect(DisplayCoordinates.appKitFrame(fromAccessibility: ax, primaryHeight: 900) == frame)
        }
    }
}
