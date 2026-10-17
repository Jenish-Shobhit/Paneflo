public enum GestureDeliveryDeadline {
    public static let maximumAgeNanoseconds: UInt64 = 250_000_000

    /// A queued input action cannot outlive its recognition by more than 250 ms.
    /// Reject clock reversal too, rather than relying on wrapping subtraction.
    public static func isFresh(recognizedAt: UInt64, now: UInt64) -> Bool {
        now >= recognizedAt && now - recognizedAt <= maximumAgeNanoseconds
    }
}
