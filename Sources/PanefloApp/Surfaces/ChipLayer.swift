import AppKit
import QuartzCore

/// SF Symbol masks rendered once per symbol, size and scale. A glyph's color is its layer's background color, so
/// appearance and accent changes recolor it with one property set and never re-render the symbol.
@MainActor
enum GlyphImages {
    private static var cache: [String: CGImage] = [:]
    #if PANEFLO_NATIVE_CHECK
    static var renders = 0
    #endif

    static func mask(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .semibold, scale: CGFloat) -> CGImage? {
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(scale)"
        if let image = cache[key] { return image }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight)) else { return nil }
        var rect = NSRect(origin: .zero, size: symbol.size)
        let hints: [NSImageRep.HintKey: Any] = [.ctm: AffineTransform(scale: scale)]
        guard let image = symbol.cgImage(forProposedRect: &rect, context: nil, hints: hints) else { return nil }
        #if PANEFLO_NATIVE_CHECK
        renders += 1
        #endif
        cache[key] = image
        return image
    }
}

/// App icon layer contents, prepared once per icon and scale and shared by every card (big icon and badge), so a
/// presentation never rasterizes an icon it has shown before.
@MainActor
enum IconContents {
    private static var cache: [ObjectIdentifier: (icon: NSImage, scale: CGFloat, contents: Any)] = [:]
    #if PANEFLO_NATIVE_CHECK
    static var misses = 0
    #endif

    static func contents(for icon: NSImage, scale: CGFloat) -> (contents: Any, scale: CGFloat) {
        let scale = icon.recommendedLayerContentsScale(scale)
        let key = ObjectIdentifier(icon)
        if let entry = cache[key], entry.icon === icon, entry.scale == scale { return (entry.contents, scale) }
        #if PANEFLO_NATIVE_CHECK
        misses += 1
        #endif
        if cache.count > 96 { cache.removeAll(keepingCapacity: true) }
        let contents = icon.layerContents(forContentsScale: scale)
        cache[key] = (icon, scale, contents)
        return (contents, scale)
    }
}

/// A tinted SF Symbol: a solid layer masked by the symbol.
final class GlyphLayer: CALayer {
    private let maskLayer = CALayer()
    private(set) var symbolName: String?
    private var renderedKey: String?

    override init() {
        super.init()
        maskLayer.contentsGravity = .resizeAspect
        mask = maskLayer
        actions = Self.noActions
        maskLayer.actions = Self.noActions
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    nonisolated(unsafe) static let noActions: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
        "hidden": NSNull(), "opacity": NSNull(), "backgroundColor": NSNull(), "frame": NSNull(), "path": NSNull(),
        "strokeColor": NSNull(), "fillColor": NSNull(), "lineWidth": NSNull(), "borderColor": NSNull(),
        "borderWidth": NSNull(), "string": NSNull(), "foregroundColor": NSNull(), "sublayers": NSNull(),
        "cornerRadius": NSNull(), "shadowOpacity": NSNull(), "lineDashPattern": NSNull()]

    /// Sets the symbol; renders its mask only the first time this symbol/size/scale is used anywhere.
    @MainActor func setSymbol(_ name: String?, pointSize: CGFloat, weight: NSFont.Weight = .semibold, scale: CGFloat) {
        let key = name.map { "\($0)|\(pointSize)|\(weight.rawValue)|\(scale)" }
        guard key != renderedKey else { return }
        renderedKey = key
        symbolName = name
        maskLayer.contentsScale = scale
        maskLayer.contents = name.flatMap { GlyphImages.mask($0, pointSize: pointSize, weight: weight, scale: scale) }
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        if maskLayer.frame != bounds { maskLayer.frame = bounds }
    }
}

/// A capsule over preview pixels holding one glyph: dark translucent in both appearances, white glyph. Used for the
/// subtle state indicator, the layout/pin corner chip, the pair link and the snap-assist ghost.
final class ChipLayer: CALayer {
    static let diameter: CGFloat = 18
    let glyph = GlyphLayer()

    override init() {
        super.init()
        actions = GlyphLayer.noActions
        masksToBounds = false
        addSublayer(glyph)
        isHidden = true
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Shows `symbol` (nil hides the chip) on `fill`, glyph in `tint`.
    @MainActor func show(_ symbol: String?, fill: CGColor, tint: CGColor, scale: CGFloat, glyphSize: CGFloat = 9) {
        guard let symbol else { if !isHidden { isHidden = true }; return }
        glyph.setSymbol(symbol, pointSize: glyphSize, scale: scale)
        if backgroundColor != fill { backgroundColor = fill }
        if glyph.backgroundColor != tint { glyph.backgroundColor = tint }
        if isHidden { isHidden = false }
    }

    /// Places the chip as a circle with its origin at `origin` (layer coordinates).
    @MainActor func place(at origin: CGPoint, diameter: CGFloat = ChipLayer.diameter) {
        let target = CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))
        if frame != target {
            frame = target
            cornerRadius = diameter / 2
            let inset = (diameter * 0.22).rounded()
            glyph.frame = bounds.insetBy(dx: inset, dy: inset)
        }
    }
}
