import Testing
@testable import PanefloCore

/// ⌃⌥ target resolution from a fresh Accessibility read (never the cached focus).
struct FrontWindowResolutionTests {
    private typealias C = FrontWindowResolution.Candidate
    private func window(_ source: C.Source, subrole: String = "AXStandardWindow", fullScreen: Bool = false,
                        minimized: Bool = false, size: Bool = true, position: Bool = true) -> C {
        C(source: source, role: "AXWindow", subrole: subrole, fullScreen: fullScreen, minimized: minimized,
          sizeSettable: size, positionSettable: position)
    }
    private func decide(_ candidates: [C], trusted: Bool = true, paneflo: Bool = false, finder: Bool = false) -> FrontWindowResolution.Decision {
        FrontWindowResolution.decide(accessibilityTrusted: trusted, frontmostIsPaneflo: paneflo, frontmostIsFinder: finder,
                                     candidates: candidates)
    }

    @Test func theFocusedWindowWinsThenMainThenFirstStandard() {
        #expect(decide([window(.focused), window(.main), window(.firstStandard)]) == .arrange(.focused, useParent: false, resizable: true))
        #expect(decide([window(.main), window(.firstStandard)]) == .arrange(.main, useParent: false, resizable: true))
        #expect(decide([window(.firstStandard)]) == .arrange(.firstStandard, useParent: false, resizable: true))
        // A minimized focused window (it can be reported that way) falls through to the next candidate.
        #expect(decide([window(.focused, minimized: true), window(.main)]) == .arrange(.main, useParent: false, resizable: true))
        #expect(decide([]) == .fail(.noWindow))
    }

    @Test func finderWithoutAFocusedWindowMeansTheDesktopNotARandomWindow() {
        #expect(decide([window(.firstStandard)], finder: true) == .fail(.noWindow))
        #expect(decide([window(.focused)], finder: true) == .arrange(.focused, useParent: false, resizable: true))
    }

    @Test func sheetsAndDialogsArrangeTheirParentWindow() {
        let sheet = C(source: .focused, role: "AXSheet", subrole: nil, hasParentWindow: true)
        #expect(decide([sheet]) == .arrange(.focused, useParent: true, resizable: true))
        let dialog = C(source: .focused, role: "AXWindow", subrole: "AXDialog", hasParentWindow: true)
        #expect(decide([dialog]) == .arrange(.focused, useParent: true, resizable: true))
        // A free-standing dialog is a window of its own; a system dialog never is.
        #expect(decide([C(source: .focused, role: "AXWindow", subrole: "AXDialog")]) == .arrange(.focused, useParent: false, resizable: true))
        #expect(decide([C(source: .focused, role: "AXWindow", subrole: "AXSystemDialog"), window(.main)]) == .arrange(.main, useParent: false, resizable: true))
        #expect(decide([C(source: .focused, role: "AXSheet", subrole: nil)]) == .fail(.noWindow))
    }

    @Test func fullScreenNonMovableAndNonResizableWindowsSayWhy() {
        #expect(decide([window(.focused, fullScreen: true)]) == .fail(.fullScreen))
        #expect(decide([window(.focused, size: false, position: false)]) == .fail(.notMovable))
        #expect(decide([window(.focused, size: false)]) == .arrange(.focused, useParent: false, resizable: false))
    }

    @Test func permissionAndOwnWindowsComeFirst() {
        #expect(decide([window(.focused)], trusted: false) == .fail(.accessibilityOff))
        #expect(decide([window(.focused)], paneflo: true) == .fail(.ownWindow))
        #expect(FrontWindowResolution.Failure.fullScreen.message == "Can’t arrange a full-screen window")
        #expect(FrontWindowResolution.Failure.accessibilityOff.message.contains("Grant Accessibility"))
    }
}
