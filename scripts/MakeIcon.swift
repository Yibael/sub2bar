import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: s); transform.concat()
        let plate = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 200, yRadius: 200)
        NSColor(calibratedWhite: 0.09, alpha: 1).setFill(); plate.fill()
        for y in [310.0, 548.0] {
            let server = NSBezierPath(roundedRect: NSRect(x: 244, y: y, width: 536, height: 164), xRadius: 46, yRadius: 46)
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill(); server.fill()
            NSColor(calibratedWhite: 0.15, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 296, y: y + 59, width: 46, height: 46)).fill()
            NSBezierPath(roundedRect: NSRect(x: 405, y: y + 68, width: 208, height: 28), xRadius: 14, yRadius: 14).fill()
            NSBezierPath(ovalIn: NSRect(x: 660, y: y + 68, width: 28, height: 28)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
}
