import Testing
@testable import PanefloCore

struct GridNavigationTests {
    @Test func preservesColumnAndSkipsVacanciesAndFilteredRows() {
        #expect(GridNavigation.vertical(from: 1, columns: 4, count: 12, eligible: [0, 1, 8, 10, 11], direction: 1) == 8)
        #expect(GridNavigation.vertical(from: 10, columns: 4, count: 12, eligible: [1, 2, 10], direction: -1) == 2)
    }
    @Test func partialRowAndEdgesDoNotWrap() {
        #expect(GridNavigation.vertical(from: 3, columns: 4, count: 6, eligible: [0, 1, 2, 3, 4, 5], direction: 1) == 5)
        #expect(GridNavigation.vertical(from: 1, columns: 4, count: 6, eligible: [1, 5], direction: -1) == nil)
        #expect(GridNavigation.vertical(from: nil, columns: 4, count: 6, eligible: [2, 5], direction: 1) == 2)
    }
}
