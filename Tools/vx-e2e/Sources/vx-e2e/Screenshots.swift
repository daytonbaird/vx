import CoreGraphics
import Foundation
import ImageIO

/// Window and region capture via `/usr/sbin/screencapture`.
///
/// The CLI is used rather than `CGWindowListCreateImage` because the latter returns
/// a blank image when Screen Recording is not granted, with no error — screencapture
/// at least exits non-zero. `preflight` checks `CGPreflightScreenCaptureAccess()`.
enum Screenshots {
    static var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestAccess() -> Bool { CGRequestScreenCaptureAccess() }

    /// Captures one window by its CGWindowID. `-x` suppresses the shutter sound;
    /// `-o` drops the window shadow so diffs are not dominated by translucency.
    @discardableResult
    static func captureWindow(id: CGWindowID, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let result = Shell.run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(id), url.path], timeout: 20)
        return result.status == 0 && FileManager.default.fileExists(atPath: url.path)
    }

    /// Captures a screen rectangle. Used for the open status menu, which is a separate
    /// window owned by the system, not by vx, so `-l <vx window>` cannot reach it.
    @discardableResult
    static func captureRegion(_ rect: CGRect, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let spec = "\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height))"
        let result = Shell.run("/usr/sbin/screencapture", ["-x", "-R", spec, url.path], timeout: 20)
        return result.status == 0 && FileManager.default.fileExists(atPath: url.path)
    }

    /// The screen region an open status menu occupies, derived from the status item's
    /// AX frame. The menu drops below the item and is wider than it, so the box is
    /// padded generously — this is for eyeballing, not for pixel-exact diffing.
    static func statusMenuRegion(statusItemFrame: CGRect, height: CGFloat = 420, width: CGFloat = 320) -> CGRect {
        CGRect(
            x: max(0, statusItemFrame.midX - width / 2),
            y: statusItemFrame.origin.y,
            width: width,
            height: height
        )
    }

    // MARK: - Diffing

    struct Diff {
        let differingPixels: Int
        let totalPixels: Int
        var percentage: Double {
            totalPixels == 0 ? 0 : Double(differingPixels) / Double(totalPixels) * 100
        }
    }

    /// Advisory pixel comparison against a baseline of the same filename.
    ///
    /// Never fails a scenario: font rendering, wallpaper bleed-through in vibrancy,
    /// and display scaling all shift pixels legitimately. The number goes in the
    /// report so a human can spot a real regression.
    static func diff(_ lhs: URL, _ rhs: URL, tolerance: Int = 12) -> Diff? {
        guard let a = loadPixels(lhs), let b = loadPixels(rhs) else { return nil }
        guard a.width == b.width, a.height == b.height else { return nil }
        var differing = 0
        let count = a.width * a.height
        for i in 0..<count {
            let offset = i * 4
            let dr = abs(Int(a.bytes[offset]) - Int(b.bytes[offset]))
            let dg = abs(Int(a.bytes[offset + 1]) - Int(b.bytes[offset + 1]))
            let db = abs(Int(a.bytes[offset + 2]) - Int(b.bytes[offset + 2]))
            if dr > tolerance || dg > tolerance || db > tolerance { differing += 1 }
        }
        return Diff(differingPixels: differing, totalPixels: count)
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    /// Decodes to a fixed RGBA8 layout so two images from different capture paths
    /// (Retina vs not, PNG vs TIFF) are comparable byte for byte.
    private static func loadPixels(_ url: URL) -> Pixels? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let byteCount = width * height * 4
        // Owned allocation rather than an Array's buffer: the CGContext outlives any
        // `withUnsafeMutableBytes` closure, and handing it a temporary pointer is UB.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 4)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: buffer,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: info
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = Array(UnsafeRawBufferPointer(start: buffer, count: byteCount))
        return Pixels(width: width, height: height, bytes: bytes)
    }
}
