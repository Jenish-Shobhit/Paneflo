#!/usr/bin/env swift
// Draws Paneflo's app icon with CoreGraphics and packs it into an .icns with iconutil.
//
//   swift scripts/make-icon.swift [output.icns] [--png preview.png]
//
// Default output: Resources/AppIcon.icns (run from the repo root). Every size is drawn from
// vectors rather than downsampled, so the small sizes stay crisp.
//
// The picture: a teal macOS rounded square holding three tiled glass panes (one tall on the
// left, two stacked on the right). The top-right pane is the focused one, in coral.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Helpers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: sRGB,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
        ])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// Apple-style "continuous" rounded rect: each corner is one cubic that starts and ends
/// further along the edges than a circular arc would, so curvature eases in and out.
func continuousRoundedRect(_ r: CGRect, radius: CGFloat) -> CGPath {
    let k = min(radius * 1.45, min(r.width, r.height) / 2)  // how far along the edge a corner reaches
    let c = k * 0.36                                          // control-point distance from the corner
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + k, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - k, y: r.minY))
    p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + k),
               control1: CGPoint(x: r.maxX - c, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + c))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - k))
    p.addCurve(to: CGPoint(x: r.maxX - k, y: r.maxY),
               control1: CGPoint(x: r.maxX, y: r.maxY - c), control2: CGPoint(x: r.maxX - c, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + k, y: r.maxY))
    p.addCurve(to: CGPoint(x: r.minX, y: r.maxY - k),
               control1: CGPoint(x: r.minX + c, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - c))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + k))
    p.addCurve(to: CGPoint(x: r.minX + k, y: r.minY),
               control1: CGPoint(x: r.minX, y: r.minY + c), control2: CGPoint(x: r.minX + c, y: r.minY))
    p.closeSubpath()
    return p
}

// MARK: - Drawing (1024 × 1024 design space, origin bottom-left)

/// One frosted-glass pane: soft shadow, tinted translucent body, top sheen, bright rim and a
/// small title-bar hint. `tint` is the pane's colour; `strength` how opaque the glass is.
func glassPane(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, tint: UInt32, strength: CGFloat) {
    let path = continuousRoundedRect(rect, radius: radius)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x021F1C, 0.45))
    ctx.addPath(path)
    ctx.setFillColor(rgb(tint, strength))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    // Light falls from the top: brighter at the top edge, clearer at the bottom.
    ctx.drawLinearGradient(
        gradient([(0, rgb(0xFFFFFF, 0.0)), (1, rgb(0xFFFFFF, 0.38))]),
        start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
    ctx.setFillColor(rgb(0xFFFFFF, 0.16))
    ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 46, width: rect.width, height: 46))
    // Three tiny traffic-light dots.
    for i in 0..<3 {
        let d: CGFloat = 14
        ctx.setFillColor(rgb(0xFFFFFF, 0.55))
        ctx.fillEllipse(in: CGRect(x: rect.minX + 24 + CGFloat(i) * 26, y: rect.maxY - 23 - d / 2, width: d, height: d))
    }
    ctx.restoreGState()

    // Rim.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.addPath(continuousRoundedRect(rect.insetBy(dx: 2, dy: 2), radius: radius - 2))
    ctx.setLineWidth(4)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.62))
    ctx.strokePath()
    ctx.restoreGState()
}

func drawIcon(in ctx: CGContext) {
    // macOS icon grid: an 824 pt body centred in 1024, corner radius ≈ 185.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = continuousRoundedRect(body, radius: 165)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x01201C, 0.45))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0x0B7A6E))
    ctx.fillPath()
    ctx.restoreGState()

    // Body: bright teal at the top to deep teal at the bottom.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x35C7B2)), (0.5, rgb(0x0E8F80)), (1, rgb(0x064B45))]),
        start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.drawRadialGradient(
        gradient([(0, rgb(0xFFFFFF, 0.30)), (1, rgb(0xFFFFFF, 0))]),
        startCenter: CGPoint(x: 340, y: 910), startRadius: 0,
        endCenter: CGPoint(x: 340, y: 910), endRadius: 600, options: [])
    // A warm coral bloom bottom-right, so the coral pane sits in coherent light.
    ctx.drawRadialGradient(
        gradient([(0, rgb(0xFF8A6B, 0.12)), (1, rgb(0xFF8A6B, 0))]),
        startCenter: CGPoint(x: 800, y: 160), startRadius: 0,
        endCenter: CGPoint(x: 800, y: 160), endRadius: 460, options: [])

    // Panes: a tall one on the left, two stacked on the right (a tiled layout).
    let gap: CGFloat = 36
    let inner = body.insetBy(dx: 98, dy: 112)
    let leftW = (inner.width - gap) * 0.46
    let rightW = inner.width - gap - leftW
    let rightH = (inner.height - gap) / 2
    let left = CGRect(x: inner.minX, y: inner.minY, width: leftW, height: inner.height)
    let topRight = CGRect(x: inner.minX + leftW + gap, y: inner.minY + rightH + gap, width: rightW, height: rightH)
    let bottomRight = CGRect(x: topRight.minX, y: inner.minY, width: rightW, height: rightH)

    glassPane(ctx, left, radius: 46, tint: 0xFFFFFF, strength: 0.30)
    glassPane(ctx, bottomRight, radius: 46, tint: 0xFFFFFF, strength: 0.22)
    glassPane(ctx, topRight, radius: 46, tint: 0xFF7A57, strength: 0.92)  // the focused pane
    ctx.restoreGState()

    // Hairline highlight along the body's edge.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.addPath(continuousRoundedRect(body.insetBy(dx: 2, dy: 2), radius: 163.6))
    ctx.setLineWidth(4)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.22))
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Output

func render(pixels: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)
    drawIcon(in: ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot create \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

var args = Array(CommandLine.arguments.dropFirst())
var previewURL: URL?
if let i = args.firstIndex(of: "--png"), i + 1 < args.count {
    previewURL = URL(fileURLWithPath: args[i + 1])
    args.removeSubrange(i...(i + 1))
}
let outputURL = URL(fileURLWithPath: args.first ?? "Resources/AppIcon.icns")

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("paneflo-icon-\(UUID().uuidString)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }

for base in [16, 32, 128, 256, 512] {
    writePNG(render(pixels: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(pixels: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if let previewURL { writePNG(render(pixels: 1024), to: previewURL) }

try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed (\(iconutil.terminationStatus))") }
print("Wrote \(outputURL.path)")
