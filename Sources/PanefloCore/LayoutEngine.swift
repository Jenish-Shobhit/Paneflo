import Foundation

public struct WindowSize: Equatable, Codable, Sendable {
    public var width: Double
    public var height: Double
    public static let zero = WindowSize(width: 0, height: 0)

    public init(width: Double, height: Double) { self.width = width; self.height = height }
    fileprivate var isValid: Bool { width.isFinite && height.isFinite && width >= 0 && height >= 0 }
}

/// Logical points in one consistent coordinate space. Platform coordinate conversion is external.
public struct WindowRect: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public static let zero = WindowRect(x: 0, y: 0, width: 0, height: 0)

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var size: WindowSize { WindowSize(width: width, height: height) }
    public var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && maxX.isFinite && maxY.isFinite && width > 0 && height > 0
    }

    public func contains(_ rect: WindowRect) -> Bool {
        isValid && rect.isValid && rect.x >= x && rect.y >= y && rect.maxX <= maxX && rect.maxY <= maxY
    }
}

public enum LayoutZone: String, CaseIterable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case firstThird, middleThird, lastThird
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter
    case center, maximize
}

public extension LayoutZone {
    /// The arrangement a surface card shows after a tile (its accessibility label says it too).
    var feedbackTitle: String {
        switch self {
        case .leftHalf: "Left half"
        case .rightHalf: "Right half"
        case .topHalf: "Top half"
        case .bottomHalf: "Bottom half"
        case .firstThird: "First third"
        case .middleThird: "Middle third"
        case .lastThird: "Last third"
        case .topLeftQuarter: "Top left quarter"
        case .topRightQuarter: "Top right quarter"
        case .bottomLeftQuarter: "Bottom left quarter"
        case .bottomRightQuarter: "Bottom right quarter"
        case .center: "Centered"
        case .maximize: "Fill screen"
        }
    }

    /// The SF Symbol for `feedbackTitle`.
    var feedbackSymbol: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .firstThird: "rectangle.leadingthird.inset.filled"
        case .middleThird: "rectangle.center.inset.filled"
        case .lastThird: "rectangle.trailingthird.inset.filled"
        case .topLeftQuarter: "rectangle.inset.topleft.filled"
        case .topRightQuarter: "rectangle.inset.topright.filled"
        case .bottomLeftQuarter: "rectangle.inset.bottomleft.filled"
        case .bottomRightQuarter: "rectangle.inset.bottomright.filled"
        case .center: "rectangle.inset.filled"
        case .maximize: "rectangle.fill"
        }
    }

    /// The zone a `feedbackTitle` names.
    init?(feedbackTitle: String) {
        guard let zone = Self.allCases.first(where: { $0.feedbackTitle == feedbackTitle }) else { return nil }
        self = zone
    }
}

public enum LayoutRejection: Equatable, Sendable {
    case invalidInput, insufficientSpace, minimumSize
}

public enum LayoutResult: Equatable, Sendable {
    case success(WindowRect)
    case rejected(LayoutRejection)

    public var rect: WindowRect? {
        if case let .success(rect) = self { return rect }
        return nil
    }
}

public enum LayoutEngine {
    public static func plan(zone: LayoutZone, in bounds: WindowRect, gap: Double = 0,
                            backingScale: Double = 1, minimumSize: WindowSize = .zero,
                            currentSize: WindowSize? = nil) -> LayoutResult {
        guard bounds.isValid, gap.isFinite, gap >= 0, validScale(backingScale), minimumSize.isValid,
              currentSize?.isValid != false else { return .rejected(.invalidInput) }
        let inset = WindowRect(x: bounds.x + gap, y: bounds.y + gap,
                               width: bounds.width - 2 * gap, height: bounds.height - 2 * gap)
        guard let inner = alignedInside(inset, scale: backingScale) else { return .rejected(.insufficientSpace) }
        let gap = (gap * backingScale).rounded(.up) / backingScale
        let proposed: WindowRect
        switch zone {
        case .leftHalf: proposed = cell(inner, columns: 2, rows: 1, column: 0, row: 0, gap: gap)
        case .rightHalf: proposed = cell(inner, columns: 2, rows: 1, column: 1, row: 0, gap: gap)
        case .topHalf: proposed = cell(inner, columns: 1, rows: 2, column: 0, row: 0, gap: gap)
        case .bottomHalf: proposed = cell(inner, columns: 1, rows: 2, column: 0, row: 1, gap: gap)
        case .firstThird: proposed = cell(inner, columns: 3, rows: 1, column: 0, row: 0, gap: gap)
        case .middleThird: proposed = cell(inner, columns: 3, rows: 1, column: 1, row: 0, gap: gap)
        case .lastThird: proposed = cell(inner, columns: 3, rows: 1, column: 2, row: 0, gap: gap)
        case .topLeftQuarter: proposed = cell(inner, columns: 2, rows: 2, column: 0, row: 0, gap: gap)
        case .topRightQuarter: proposed = cell(inner, columns: 2, rows: 2, column: 1, row: 0, gap: gap)
        case .bottomLeftQuarter: proposed = cell(inner, columns: 2, rows: 2, column: 0, row: 1, gap: gap)
        case .bottomRightQuarter: proposed = cell(inner, columns: 2, rows: 2, column: 1, row: 1, gap: gap)
        case .maximize: proposed = inner
        case .center:
            let size = currentSize ?? WindowSize(width: inner.width * 0.6, height: inner.height * 0.6)
            guard size.width > 0, size.height > 0, size.width <= inner.width, size.height <= inner.height else {
                return .rejected(.insufficientSpace)
            }
            proposed = WindowRect(x: inner.x + (inner.width - size.width) / 2,
                                  y: inner.y + (inner.height - size.height) / 2,
                                  width: size.width, height: size.height)
        }
        // Shared grid boundaries round to the same pixel, avoiding seams between adjacent zero-gap cells.
        guard proposed.isValid else { return .rejected(.insufficientSpace) }
        let x = max(inner.x, (proposed.x * backingScale).rounded() / backingScale)
        let y = max(inner.y, (proposed.y * backingScale).rounded() / backingScale)
        let right = min(inner.maxX, (proposed.maxX * backingScale).rounded() / backingScale)
        let bottom = min(inner.maxY, (proposed.maxY * backingScale).rounded() / backingScale)
        let aligned = WindowRect(x: x, y: y, width: right - x, height: bottom - y)
        guard aligned.isValid else { return .rejected(.insufficientSpace) }
        guard aligned.width >= minimumSize.width, aligned.height >= minimumSize.height else {
            return .rejected(.minimumSize)
        }
        return .success(aligned)
    }

    /// Recovery may shrink a requested rectangle; the adapter still must validate actual app constraints.
    public static func recover(_ rect: WindowRect, in bounds: WindowRect, backingScale: Double = 1) -> LayoutResult {
        guard rect.isValid, bounds.isValid, validScale(backingScale) else { return .rejected(.invalidInput) }
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        let result = WindowRect(x: clamp(rect.x, bounds.x, bounds.maxX - width),
                                y: clamp(rect.y, bounds.y, bounds.maxY - height), width: width, height: height)
        guard let aligned = alignedInside(result, scale: backingScale) else { return .rejected(.insufficientSpace) }
        return .success(aligned)
    }

    public static func transfer(_ rect: WindowRect, from source: WindowRect, to destination: WindowRect,
                                backingScale: Double = 1, edgeTolerance: Double = 1) -> LayoutResult {
        guard rect.isValid, source.isValid, destination.isValid, validScale(backingScale),
              edgeTolerance.isFinite, edgeTolerance >= 0 else { return .rejected(.invalidInput) }
        let left = rect.x - source.x <= edgeTolerance
        let right = source.maxX - rect.maxX <= edgeTolerance
        let top = rect.y - source.y <= edgeTolerance
        let bottom = source.maxY - rect.maxY <= edgeTolerance
        var (x, width) = transferAxis(origin: rect.x, length: rect.width, sourceOrigin: source.x,
                                     sourceLength: source.width, destinationOrigin: destination.x,
                                     destinationLength: destination.width, first: left, last: right)
        var (y, height) = transferAxis(origin: rect.y, length: rect.height, sourceOrigin: source.y,
                                      sourceLength: source.height, destinationOrigin: destination.y,
                                      destinationLength: destination.height, first: top, last: bottom)
        let orientationChanged = (source.width > source.height && destination.width < destination.height)
            || (source.width < source.height && destination.width > destination.height)
        if orientationChanged {
            if left && right && top != bottom {
                width = min(rect.width, destination.width)
                x = destination.x + (destination.width - width) / 2
            }
            if top && bottom && left != right {
                height = min(rect.height, destination.height)
                y = destination.y + (destination.height - height) / 2
            }
        }
        return recover(WindowRect(x: x, y: y, width: width, height: height),
                       in: destination, backingScale: backingScale)
    }

    private static func cell(_ bounds: WindowRect, columns: Int, rows: Int, column: Int,
                             row: Int, gap: Double) -> WindowRect {
        let width = (bounds.width - Double(columns - 1) * gap) / Double(columns)
        let height = (bounds.height - Double(rows - 1) * gap) / Double(rows)
        return WindowRect(x: bounds.x + Double(column) * (width + gap),
                          y: bounds.y + Double(row) * (height + gap), width: width, height: height)
    }

    private static func alignedInside(_ rect: WindowRect, scale: Double) -> WindowRect? {
        guard rect.isValid else { return nil }
        let x = (rect.x * scale).rounded(.up) / scale
        let y = (rect.y * scale).rounded(.up) / scale
        let right = (rect.maxX * scale).rounded(.down) / scale
        let bottom = (rect.maxY * scale).rounded(.down) / scale
        let result = WindowRect(x: x, y: y, width: right - x, height: bottom - y)
        return result.isValid ? result : nil
    }

    private static func validScale(_ scale: Double) -> Bool { scale.isFinite && scale > 0 }

    private static func transferAxis(origin: Double, length: Double, sourceOrigin: Double,
                                     sourceLength: Double, destinationOrigin: Double,
                                     destinationLength: Double, first: Bool, last: Bool) -> (Double, Double) {
        let startInset = max(0, origin - sourceOrigin)
        let endInset = max(0, sourceOrigin + sourceLength - origin - length)
        if first && last {
            let start = min(startInset, destinationLength / 2)
            let end = min(endInset, destinationLength / 2)
            return (destinationOrigin + start, destinationLength - start - end)
        }
        let size = min(length, destinationLength)
        if first { return (destinationOrigin + min(startInset, destinationLength - size), size) }
        if last { return (destinationOrigin + destinationLength - size - min(endInset, destinationLength - size), size) }
        let fraction = (origin + length / 2 - sourceOrigin) / sourceLength
        return (clamp(destinationOrigin + fraction * destinationLength - size / 2,
                      destinationOrigin, destinationOrigin + destinationLength - size), size)
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
