import Foundation
import Testing
@testable import PanefloCore

struct MenuBarIconPolicyTests {
    @Test func hidingAsksOnceUntilDontShowAgainThenHidesAtOnce() {
        var policy = MenuBarIconPolicy()
        #expect(policy.isVisible && policy.hideStep(attention: .none) == .confirm)
        policy.hide(dontAskAgain: false)
        #expect(!policy.isVisible && policy.hideStep(attention: .none) == .refuse)
        #expect(policy.show() && !policy.show())
        #expect(policy.hideStep(attention: .none) == .confirm)
        policy.hide(dontAskAgain: true)
        policy.show()
        #expect(policy.hideStep(attention: .none) == .hide && policy.skipsConfirmation)
    }

    @Test func reopeningPaneflowBringsAHiddenIconBack() {
        var policy = MenuBarIconPolicy(hidden: true)
        #expect(policy.reopened() && policy.isVisible)
        // Reopening with the icon already visible changes nothing (Settings shows no "restored" note).
        #expect(!policy.reopened() && policy.isVisible)
    }

    @Test func attentionNeverLetsTheIconStayHidden() {
        var policy = MenuBarIconPolicy(hidden: true, skipsConfirmation: true)
        #expect(!policy.attentionChanged(.none) && policy.hidden)
        #expect(policy.attentionChanged(.setupNeeded) && policy.isVisible)
        // While something needs attention, hiding is refused even without the confirmation.
        #expect(policy.hideStep(attention: .setupNeeded) == .refuse && policy.hideStep(attention: .shortcutsStopped) == .refuse)
        policy.hide(dontAskAgain: false)
        #expect(policy.attentionChanged(.shortcutsStopped) && policy.isVisible)
    }

    @Test func attentionComesFromSetupOrStoppedShortcutsTheUserWants() {
        #expect(MenuBarIconPolicy.attention(status: .setupNeeded, shortcutsWanted: false, shortcutsStopped: false) == .setupNeeded)
        #expect(MenuBarIconPolicy.attention(status: .starting, shortcutsWanted: true, shortcutsStopped: true) == .shortcutsStopped)
        // The user's own pause, or a normal start, is not a reason to bring the icon back.
        #expect(MenuBarIconPolicy.attention(status: .paused, shortcutsWanted: false, shortcutsStopped: true) == .none)
        #expect(MenuBarIconPolicy.attention(status: .starting, shortcutsWanted: true, shortcutsStopped: false) == .none)
        #expect(MenuBarIconPolicy.attention(status: .ready, shortcutsWanted: true, shortcutsStopped: false) == .none)
    }

    @Test func thePolicyPersistsInSetupPreferences() throws {
        let suite = "paneflo.tests.menu-bar-icon.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SetupPreferences(defaults: defaults)
        #expect(preferences.menuBarIcon == MenuBarIconPolicy())
        var policy = preferences.menuBarIcon
        policy.hide(dontAskAgain: true)
        preferences.menuBarIcon = policy
        #expect(SetupPreferences(defaults: defaults).menuBarIcon == MenuBarIconPolicy(hidden: true, skipsConfirmation: true))
        // The Settings switch's key is the same one.
        #expect(defaults.bool(forKey: SetupPreferences.menuBarIconHiddenKey))
    }
}
