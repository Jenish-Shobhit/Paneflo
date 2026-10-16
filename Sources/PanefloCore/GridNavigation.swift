/// Vertical board movement preserves column where possible and skips unavailable rows.
public enum GridNavigation {
    public static func vertical(from current: Int?, columns: Int, count: Int, eligible: [Int], direction: Int) -> Int? {
        guard columns > 0, count > 0, direction != 0 else { return nil }
        let candidates = eligible.filter { $0 >= 0 && $0 < count }
        guard let current, current >= 0, current < count else {
            return direction > 0 ? candidates.min() : candidates.max()
        }
        let row = current / columns
        let column = current % columns
        let step = direction > 0 ? 1 : -1
        var nextRow = row + step
        while nextRow >= 0, nextRow <= (count - 1) / columns {
            if let match = candidates.filter({ $0 / columns == nextRow }).min(by: {
                let a = abs($0 % columns - column), b = abs($1 % columns - column)
                return a == b ? $0 < $1 : a < b
            }) { return match }
            nextRow += step
        }
        return nil
    }
}
