// This is the standalone synthetic regression harness for CaptureController's
// provider-backed BGRA image ownership. The test script concatenates this file
// after CaptureController.swift so fileprivate helpers remain testable without
// changing production visibility.
import AppKit
import CoreVideo
import CoreGraphics

@main struct CaptureOwnershipCheck {
    static func makeBuffer() -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                     kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 4, 2, kCVPixelFormatType_32BGRA,
                                        attrs as CFDictionary, &created) == kCVReturnSuccess)
        let buffer = created!
        precondition(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        let data = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<2 {
            for x in 0..<4 {
                let offset = y * stride + x * 4
                data[offset] = y == 0 ? 0 : 255
                data[offset + 1] = x == 0 ? 0 : 255
                data[offset + 2] = y == 0 ? 255 : 0
                data[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
    static func validatePixels(_ image: CGImage) {
        let bytes = image.dataProvider!.data!
        let pixels = CFDataGetBytePtr(bytes)!
        precondition(pixels[0] == 0 && pixels[1] == 0 && pixels[2] == 255 && pixels[3] == 255)
        let secondRow = image.bytesPerRow
        precondition(pixels[secondRow] == 255 && pixels[secondRow + 2] == 0)
        // A small CPU context validates BGRA interpretation using the actual provider-backed image.
        var drawn = [UInt8](repeating: 0, count: 4 * 2 * 4)
        drawn.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress, width: 4, height: 2,
                bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 2))
        }
        precondition(drawn[0] == 0 && drawn[2] == 255 && drawn[16] == 255 && drawn[18] == 0)
    }
    static func main() {
        precondition(!PreviewRenderer.usesReferenceRenderer)
        let budget = CaptureBufferBudget()
        let output = CaptureOutput(budget: budget, onImage: { _ in }, onStop: {})
        let one = makeBuffer(), two = makeBuffer(), three = makeBuffer()
        var first: CGImage? = output.makeImage(from: one)
        precondition(first != nil && budget.counts.current == 1)
        precondition(first!.bytesPerRow == CVPixelBufferGetBytesPerRow(one))
        autoreleasepool { validatePixels(first!) }
        var second: CGImage? = output.makeImage(from: two)
        precondition(second != nil && budget.counts.current == 2)
        precondition(output.makeImage(from: three) == nil && budget.counts.current == 2)
        var retainedProvider: CGDataProvider? = first!.dataProvider
        first = nil
        precondition(retainedProvider != nil && budget.counts.current == 2)
        retainedProvider = nil
        precondition(budget.counts.current == 1)
        var third: CGImage? = output.makeImage(from: three)
        precondition(third != nil && budget.counts.current == 2)
        second = nil; third = nil
        precondition(budget.counts.current == 0 && budget.counts.peak == 2)
        // A static cache image must not retain a live provider or consume its scarce lease.
        var liveSource: CGImage? = output.makeImage(from: one)
        precondition(liveSource != nil && budget.counts.current == 1)
        let detached = CaptureController.detachedThumbnail(liveSource!)!
        liveSource = nil
        precondition(budget.counts.current == 0)
        autoreleasepool { validatePixels(detached) }
        precondition(budget.counts.current == 0)
        output.deactivate()
        print("PASS detached thumbnail holds no live lease; provider pixels/row-stride/color draw; provider retains lease after image release; lease cap 2; rejection/re-admission; final leases 0")
    }
}
