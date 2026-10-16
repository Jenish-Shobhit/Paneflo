import AppKit
import PanefloCore

@MainActor
struct SampleAppearance {
    let symbol: String
    let color: NSColor

    static func forRecord(_ record: WindowRecord) -> Self {
        switch record.appIdentifier {
        case "sample.editor": Self(symbol: "chevron.left.forwardslash.chevron.right", color: .systemPurple)
        case "sample.browser": Self(symbol: "globe", color: .systemBlue)
        case "sample.terminal": Self(symbol: "terminal", color: .systemGreen)
        case "sample.messages": Self(symbol: "bubble.left.and.bubble.right", color: .systemOrange)
        default: Self(symbol: "folder", color: .systemTeal)
        }
    }
}

@MainActor
final class SampleCard: NSButton {
    var handleKey: ((NSEvent) -> Bool)?
    var record: WindowRecord? { didSet { refreshAccessibility(); needsDisplay = true } }
    var isSelectedCard = false { didSet { refreshAccessibility(); needsDisplay = true } }
    var isPinned = false { didSet { refreshAccessibility(); needsDisplay = true } }
    var isMatching = true { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 260, height: 170) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        focusRingType = .exterior
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func keyDown(with event: NSEvent) {
        if handleKey?(event) != true { super.keyDown(with: event) }
    }

    private func refreshAccessibility() {
        guard let record else {
            setAccessibilityLabel(isPinned ? "Pinned vacant sample slot" : "Vacant sample slot")
            return
        }
        setAccessibilityLabel("Sample window, \(record.appName), \(record.title)\(isPinned ? ", pinned" : "")")
        setAccessibilityValue(isSelectedCard ? "Selected" : "Not selected")
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath(roundedRect: inset, xRadius: 13, yRadius: 13)
        (isSelectedCard ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isSelectedCard ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isSelectedCard ? 2 : 1
        path.stroke()

        guard let record else {
            drawText(isPinned ? "Pinned vacancy" : "Vacant slot", in: NSRect(x: 18, y: 63, width: bounds.width - 36, height: 25), font: .systemFont(ofSize: 14, weight: .medium), color: .secondaryLabelColor)
            return
        }

        let appearance = SampleAppearance.forRecord(record)
        let muted = isMatching ? 1.0 : 0.25
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(muted)
        let icon = NSImage(systemSymbolName: appearance.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        icon?.draw(in: NSRect(x: 17, y: 17, width: 21, height: 19))
        drawText(record.appName, in: NSRect(x: 47, y: 17, width: bounds.width - 75, height: 20), font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
        if isPinned {
            NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?.draw(in: NSRect(x: bounds.width - 33, y: 19, width: 12, height: 14))
        }

        let preview = NSRect(x: 17, y: 46, width: bounds.width - 34, height: max(45, bounds.height - 99))
        appearance.color.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: preview, xRadius: 6, yRadius: 6).fill()
        for line in 0..<4 {
            let widths = [0.68, 0.43, 0.78, 0.54]
            appearance.color.withAlphaComponent(line == 0 ? 0.6 : 0.24).setFill()
            NSBezierPath(roundedRect: NSRect(x: preview.minX + 12, y: preview.minY + 13 + Double(line) * 12, width: (preview.width - 24) * widths[line], height: 4), xRadius: 2, yRadius: 2).fill()
        }
        drawText(record.title, in: NSRect(x: 18, y: bounds.height - 45, width: bounds.width - 36, height: 20), font: .systemFont(ofSize: 12, weight: .medium), color: .labelColor)
        drawText(record.isMinimized ? "SAMPLE · MINIMIZED" : "SYNTHETIC WINDOW", in: NSRect(x: 18, y: bounds.height - 25, width: bounds.width - 36, height: 15), font: .systemFont(ofSize: 9, weight: .medium), color: .secondaryLabelColor)
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
}

@MainActor
final class LayoutPreviewView: NSView {
    var usable = WindowRect(x: 0, y: 0, width: 1440, height: 900) { didSet { needsDisplay = true } }
    var applied = WindowRect(x: 160, y: 130, width: 780, height: 560) { didSet { needsDisplay = true } }
    var proposed: WindowRect? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Synthetic desktop layout preview")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill()
        let scale = min((bounds.width - 60) / usable.width, (bounds.height - 50) / usable.height)
        let desktop = NSRect(x: (bounds.width - usable.width * scale) / 2, y: (bounds.height - usable.height * scale) / 2, width: usable.width * scale, height: usable.height * scale)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: desktop, xRadius: 7, yRadius: 7).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: desktop, xRadius: 7, yRadius: 7).stroke()

        func mapped(_ rect: WindowRect) -> NSRect {
            NSRect(x: desktop.minX + (rect.x - usable.x) * scale, y: desktop.minY + (rect.y - usable.y) * scale, width: rect.width * scale, height: rect.height * scale)
        }
        let current = mapped(applied)
        NSColor.systemPurple.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: current, xRadius: 5, yRadius: 5).fill()
        drawText("Sample editor", in: current.insetBy(dx: 12, dy: 12), font: .systemFont(ofSize: 12, weight: .medium), color: .labelColor)
        if let proposed {
            let destination = mapped(proposed)
            NSColor.controlAccentColor.withAlphaComponent(0.11).setFill()
            let path = NSBezierPath(roundedRect: destination, xRadius: 5, yRadius: 5)
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            let pattern: [CGFloat] = [7, 4]
            path.setLineDash(pattern, count: pattern.count, phase: 0)
            path.stroke()
        }
    }
}
