import Foundation
import Testing
@testable import PanefloCore

struct SwitcherLayoutTests {
    /// A 1512 × 945 pt display: 90 % of the width, 80 % of the height.
    let width = 1512.0 * 0.9, height = 945.0 * 0.8

    @Test
    func testTierFormulaMatchesSpecification() {
        #expect(CardTier.large.wellWidth == 212 && CardTier.large.wellHeight == 133 && CardTier.large.cardHeight == 192)
        #expect(CardTier.medium.wellHeight == 110 && CardTier.medium.cardHeight == 169)
        #expect(CardTier.small.wellHeight == 90 && CardTier.small.cardHeight == 149)
        #expect(!CardTier.extraSmall.showsSubtitle && CardTier.extraSmall.cardHeight == 10 + 75 + 8 + 15 + 10)
    }

    @Test
    func testReferenceGridsPickTierAndBalanceRows() {
        func plan(_ n: Int) -> SwitcherLayout { .plan(count: n, width: width, height: height, chrome: 95) }
        #expect(plan(2).tier == .large && plan(2).columns == 2 && plan(2).rows == 1)
        #expect(plan(6).tier == .medium && plan(6).columns == 6 && plan(6).rows == 1)
        #expect(plan(13).tier == .small && plan(13).columns == 7 && plan(13).rows == 2)
        #expect(plan(15).tier == .small && plan(15).columns == 5 && plan(15).rows == 3)
        let many = plan(41)
        #expect(many.tier == .extraSmall && many.columns == 7 && many.rows == 6 && many.visibleRows == 4)
        // Balanced: 8 cards on a medium-capacity screen split 4 + 4.
        let eight = SwitcherLayout.plan(count: 8, width: width, height: height, chrome: 95, forced: .medium)
        #expect(eight.rowCounts == [4, 4])
    }

    @Test
    func testForcedTierOverridesAutomaticChoice() {
        let large = SwitcherLayout.plan(count: 13, width: width, height: height, chrome: 95, forced: .large)
        #expect(large.tier == .large && large.columns == 5 && large.rows == 3)
        #expect(CardSizePreference(rawValue: "auto")?.forcedTier == nil && CardSizePreference.small.forcedTier == .small)
    }

    @Test
    func testShortLastRowIsCentred() {
        let layout = SwitcherLayout.plan(count: 5, width: width, height: height, chrome: 95, forced: .large)
        #expect(layout.columns == 5)
        let wrapped = SwitcherLayout(tier: .large, columns: 3, rows: 2, visibleRows: 2,
                                     positions: SwitcherLayout.place(count: 5, pairStarts: [], columns: 3).0, rowCounts: [3, 2])
        let pitch = wrapped.cellWidth + SwitcherLayout.gap
        #expect(wrapped.cellX(of: 0) == 0 && wrapped.cellX(of: 3) == pitch / 2 && wrapped.cellX(of: 4) == pitch * 1.5)
    }

    @Test
    func testPairNeverSplitsAcrossRows() {
        let (positions, counts) = SwitcherLayout.place(count: 8, pairStarts: [3], columns: 4)
        // The pair would start in the last cell: the next single card takes that cell, the pair opens row 2.
        #expect(positions[5] == .init(row: 0, column: 3))
        #expect(positions[3] == .init(row: 1, column: 0) && positions[4] == .init(row: 1, column: 1))
        #expect(positions[6] == .init(row: 1, column: 2) && positions[7] == .init(row: 1, column: 3))
        #expect(counts == [4, 4])
        // No single card left to fill the gap: the row ends short.
        let (tail, tailCounts) = SwitcherLayout.place(count: 5, pairStarts: [3], columns: 4)
        #expect(tail[3] == .init(row: 1, column: 0) && tail[4] == .init(row: 1, column: 1) && tailCounts == [3, 2])
        for (start, columns) in [(0, 2), (1, 2), (2, 3), (5, 3)] {
            let (spots, _) = SwitcherLayout.place(count: 9, pairStarts: [start], columns: columns)
            #expect(spots[start].row == spots[start + 1].row && spots[start + 1].column == spots[start].column + 1)
        }
    }

    @Test
    func testVerticalNavigationFollowsCentredColumns() {
        let layout = SwitcherLayout(tier: .medium, columns: 3, rows: 2, visibleRows: 2,
                                    positions: SwitcherLayout.place(count: 5, pairStarts: [], columns: 3).0, rowCounts: [3, 2])
        #expect(layout.vertical(from: 3, direction: -1) == 0)
        #expect(layout.vertical(from: 2, direction: 1) == 4)
        #expect(layout.vertical(from: 1, direction: 1) == 3)
        #expect(layout.vertical(from: 4, direction: 1) == nil)
        #expect(layout.vertical(from: 0, direction: 1, eligible: [0, 1, 2]) == nil)
        #expect(layout.vertical(from: nil, direction: 1) == 0)
    }

    @Test
    func testIndicatorsShowOnlyStatesThatMatter() {
        #expect(PreviewIndicator.resolve(.live, isMinimized: false) == (.none, 1))
        #expect(PreviewIndicator.resolve(.snapshot(capturedAt: 0, note: nil), isMinimized: false) == (.none, 1))
        #expect(PreviewIndicator.resolve(.loading, isMinimized: false) == (.none, 1))
        #expect(PreviewIndicator.resolve(.snapshot(capturedAt: 0, note: .minimized), isMinimized: true) == (.minimized, 0.55))
        #expect(PreviewIndicator.resolve(.unavailable(.appHidden), isMinimized: false) == (.appHidden, 0.55))
        #expect(PreviewIndicator.resolve(.unavailable(.otherSpace), isMinimized: false) == (.otherSpace, 0.8))
        #expect(PreviewIndicator.resolve(.unavailable(.captureFailed), isMinimized: false) == (.none, 1))
        #expect(PreviewIndicator.resolve(.paused(.memoryPressure), isMinimized: false) == (.paused, 0.8))
        #expect(PreviewIndicator.resolve(.paused(.retrying), isMinimized: false) == (.paused, 0.8))
        #expect(PreviewIndicator.resolve(nil, isMinimized: true) == (.minimized, 0.55))
        #expect(PreviewIndicator.minimized.spokenState == "Minimized" && PreviewIndicator.none.spokenState == nil)
    }

    @Test
    func testPreferencesDefaultAndRead() throws {
        let suite = "paneflo.tests.surface-preferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SurfacePreferences(defaults: defaults) == SurfacePreferences())
        defaults.set(false, forKey: "tilePairs.raiseTogether")
        #expect(!SurfacePreferences(defaults: defaults).raiseTogether)
        defaults.set(true, forKey: SurfacePreferences.Key.raiseTogether)
        defaults.set("small", forKey: SurfacePreferences.Key.cardSize)
        defaults.set(false, forKey: SurfacePreferences.Key.showsFreeSlots)
        let read = SurfacePreferences(defaults: defaults)
        #expect(read.raiseTogether && read.cardSize == .small && !read.showsFreeSlots && read.sideBySide && read.snapAssist)
        defaults.set("bogus", forKey: SurfacePreferences.Key.cardSize)
        #expect(SurfacePreferences(defaults: defaults).cardSize == .automatic)
    }

    @Test
    func testEveryOptionRoundTripsThroughItsOwnKey() throws {
        let suite = "paneflo.tests.surface-options.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Keys are distinct and every option defaults on, the selected-window title included.
        #expect(Set(SurfacePreferences.Option.allCases.map(\.key)).count == SurfacePreferences.Option.allCases.count)
        #expect(SurfacePreferences.Option.allCases.allSatisfy { SurfacePreferences()[$0] })
        #expect(SurfacePreferences.Option.showsSelectedTitle.key == "switcher.showsSelectedTitle")
        for option in SurfacePreferences.Option.allCases {
            SurfacePreferences.write(option, false, to: defaults)
            let read = SurfacePreferences(defaults: defaults)
            #expect(!read[option], "\(option) must read back off")
            // Turning one option off leaves the others alone.
            #expect(SurfacePreferences.Option.allCases.filter { $0 != option }.allSatisfy { read[$0] }, "\(option) leaked")
            SurfacePreferences.write(option, true, to: defaults)
        }
        #expect(SurfacePreferences(defaults: defaults) == SurfacePreferences())
        for size in CardSizePreference.allCases {
            SurfacePreferences.write(cardSize: size, to: defaults)
            #expect(SurfacePreferences(defaults: defaults).cardSize == size)
        }
        var preferences = SurfacePreferences()
        preferences[.snapAssist] = false
        #expect(!preferences.snapAssist && preferences.showsSelectedTitle)
    }
}
