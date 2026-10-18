/// Deterministic SplitMix64 generator for fuzz and property tests. Same seed, same sequence.
struct FuzzRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
    mutating func double(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &self) }
    mutating func chance(_ p: Double) -> Bool { double(0...1) < p }
    mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }
}

import Testing
func fail(_ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
}
