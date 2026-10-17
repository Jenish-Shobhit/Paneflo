// Standalone synthetic regression harness for CaptureController's live-frame ownership.
// Tools/test-capture-ownership.sh concatenates this file after CaptureController.swift so
// fileprivate helpers stay testable without changing production visibility, and builds it with
// AddressSanitizer. It needs no Screen Recording permission and touches no real windows.
import AppKit
import CoreVideo
import CoreGraphics
import IOSurface

private final class FrameSink: @unchecked Sendable {
    var frames: [LiveFrame] = []
}

@main struct CaptureOwnershipCheck {
    static func makeBuffer(ioSurface: Bool = true) -> CVPixelBuffer {
        var created: CVPixelBuffer?
        var attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        if ioSurface { attrs[kCVPixelBufferIOSurfacePropertiesKey] = [:] as CFDictionary }
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
        var drawn = [UInt8](repeating: 0, count: 4 * 2 * 4)
        drawn.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress, width: 4, height: 2,
                bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 2))
        }
        precondition(drawn[0] == 0 && drawn[2] == 255 && drawn[16] == 255 && drawn[18] == 0)
    }

    static func drainMain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    static func main() {
        precondition(!PreviewRenderer.usesReferenceRenderer)
        let budget = LiveFrameBudget()

        // 1. Zero copy: the delivered surface is the pixel buffer's own IOSurface.
        let one = makeBuffer(), two = makeBuffer(), three = makeBuffer(), four = makeBuffer()
        var first: LiveFrame? = LiveFrame(buffer: one, budget: budget, arrivedAt: 1)
        let backing = unsafeBitCast(CVPixelBufferGetIOSurface(one)!.takeUnretainedValue(), to: IOSurface.self)
        precondition(first != nil && first!.surface === backing && budget.counts.current == 1)
        precondition(LiveFrame(buffer: makeBuffer(ioSurface: false), budget: budget, arrivedAt: 0) == nil)
        precondition(budget.counts.current == 1, "a rejected non-IOSurface buffer takes no slot")

        // 2. Frame cap: three live frames at most; release re-admits.
        var second: LiveFrame? = LiveFrame(buffer: two, budget: budget, arrivedAt: 2)
        var third: LiveFrame? = LiveFrame(buffer: three, budget: budget, arrivedAt: 3)
        precondition(second != nil && third != nil && budget.counts.current == LiveFrameBudget.limit)
        precondition(LiveFrame(buffer: four, budget: budget, arrivedAt: 4) == nil && budget.counts.current == 3)
        third = nil
        precondition(budget.counts.current == 2)

        // 3. Legacy provider-backed CGImage keeps the frame (and its lock) until the provider is released.
        var legacy: CGImage? = CaptureController.legacyImage(from: first!)
        precondition(legacy != nil && legacy!.bytesPerRow == CVPixelBufferGetBytesPerRow(one))
        autoreleasepool { validatePixels(legacy!) }
        first = nil
        precondition(budget.counts.current == 2, "the image still owns the first frame")
        var provider: CGDataProvider? = legacy!.dataProvider
        legacy = nil
        precondition(budget.counts.current == 2, "the provider still owns the first frame")
        provider = nil
        precondition(budget.counts.current == 1)
        _ = provider

        // 4. A live frame converted to a cached snapshot owns its pixels and holds no frame slot.
        let snapshot = CaptureController.detachedSnapshot(from: second!, fitting: CGSize(width: 4, height: 2))!
        let scaled = CaptureController.detachedSnapshot(from: second!, fitting: CGSize(width: 2, height: 2))!
        second = nil
        precondition(budget.counts.current == 0)
        autoreleasepool { validatePixels(snapshot) }
        precondition(scaled.width == 2 && scaled.height == 1, "aspect-fit downscale, never upscale")
        precondition(CaptureController.fittedPixelSize(CGSize(width: 1_000, height: 500), box: CGSize(width: 464, height: 204)) == (408, 204))
        precondition(CaptureController.fittedPixelSize(CGSize(width: 100, height: 50), box: CGSize(width: 464, height: 204)) == (200, 100))

        // 5. Output mailbox: a slow main thread never queues frames, and teardown releases them.
        let sink = FrameSink()
        let output = CaptureOutput(budget: budget, onFrame: { sink.frames.append($0) }, onStop: { _ in })
        for buffer in [one, two, three, four, one] { output.ingest(buffer) }
        precondition(budget.counts.current == 1, "only the newest undelivered frame is held")
        drainMain()
        precondition(sink.frames.count == 1 && sink.frames[0].pixelBuffer === one, "latest frame delivered once")
        output.ingest(two)
        precondition(budget.counts.current == 2, "displayed + pending")
        output.deactivate()
        precondition(budget.counts.current == 1, "deactivate releases the pending frame at once")
        drainMain()
        precondition(sink.frames.count == 1, "no delivery after deactivate")
        output.ingest(three)
        precondition(budget.counts.current == 1, "ingest after deactivate is ignored")
        sink.frames.removeAll()
        precondition(budget.counts.current == 0)
        let counters = output.counters
        precondition(counters.received == 6 && counters.delivered == 1)

        precondition(budget.counts.current == 0 && budget.counts.peak == LiveFrameBudget.limit)
        print("PASS IOSurface zero-copy identity; non-IOSurface rejected; frame cap \(LiveFrameBudget.limit) with re-admission; legacy provider retains frame until released; live->snapshot conversion holds no frame; aspect-fit sizing; mailbox holds 1 pending, deactivate releases, no late delivery; final frames 0")
    }
}
