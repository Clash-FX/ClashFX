import AppKit

enum BundleIconImage {
    static let pixelDimension = 512

    private static let maximumSourceDimension: CGFloat = 65_536
    private static let minimumSourceDimension: CGFloat = 0.000_001

    static func make(from source: NSImage, addingLabBadge: Bool) -> NSImage? {
        let sourceSize = source.size
        guard sourceSize.width.isFinite,
              sourceSize.height.isFinite,
              sourceSize.width >= minimumSourceDimension,
              sourceSize.height >= minimumSourceDimension,
              sourceSize.width <= maximumSourceDimension,
              sourceSize.height <= maximumSourceDimension else { return nil }

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelDimension,
            pixelsHigh: pixelDimension,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        let canvas = NSRect(x: 0, y: 0, width: pixelDimension, height: pixelDimension)
        bitmap.size = canvas.size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        let scale = min(canvas.width / sourceSize.width, canvas.height / sourceSize.height)
        let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawRect = NSRect(
            x: (canvas.width - drawSize.width) / 2,
            y: (canvas.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.current = previousContext }

        context.imageInterpolation = .high
        NSColor.clear.setFill()
        NSBezierPath(rect: canvas).fill()

        NSGraphicsContext.saveGraphicsState()
        source.draw(
            in: drawRect,
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: nil
        )
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.current = context
        context.flushGraphics()

        if addingLabBadge {
            drawLabBadge(in: canvas)
        }

        context.flushGraphics()
        let result = NSImage(size: NSSize(width: pixelDimension, height: pixelDimension))
        result.addRepresentation(bitmap)
        return result
    }

    private static func drawLabBadge(in canvas: NSRect) {
        let dotDiameter: CGFloat = 56
        let inset: CGFloat = 71
        let dotRect = NSRect(
            x: canvas.width - inset - dotDiameter,
            y: canvas.height - inset - dotDiameter,
            width: dotDiameter,
            height: dotDiameter
        )
        let dot = NSBezierPath(ovalIn: dotRect)
        NSColor.systemOrange.setFill()
        dot.fill()
        NSColor.white.setStroke()
        dot.lineWidth = 12
        dot.stroke()
    }
}
