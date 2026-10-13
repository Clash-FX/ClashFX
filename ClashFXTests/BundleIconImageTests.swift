import AppKit
import XCTest

final class BundleIconImageTests: XCTestCase {
    func testInvalidSourceDimensionsAreRejected() {
        let invalidSource = NSImage(size: NSSize(width: 0, height: 512))

        XCTAssertNil(BundleIconImage.make(from: invalidSource, addingLabBadge: false))
    }

    func testOversizedSourceIsReducedToOneCanonicalBitmapRepresentation() throws {
        let source = makeSolidImage(width: 2048, height: 2048, color: .blue)
        let icon = try XCTUnwrap(BundleIconImage.make(from: source, addingLabBadge: false))

        assertCanonicalRepresentation(in: icon)
    }

    func testNonSquareSourceKeepsItsAspectRatio() throws {
        let source = makeSolidImage(width: 200, height: 100, color: .blue)
        let icon = try XCTUnwrap(BundleIconImage.make(from: source, addingLabBadge: false))
        let bitmap = try XCTUnwrap(icon.representations.first as? NSBitmapImageRep)
        let centerColor = try XCTUnwrap(bitmap.colorAt(x: 256, y: 256)?.usingColorSpace(.deviceRGB))
        let topColor = try XCTUnwrap(bitmap.colorAt(x: 256, y: 20)?.usingColorSpace(.deviceRGB))

        XCTAssertGreaterThan(centerColor.alphaComponent, 0.9)
        XCTAssertLessThan(topColor.alphaComponent, 0.1)
        assertCanonicalRepresentation(in: icon)
    }

    func testLabBadgeIsRenderedIntoTheCanonicalBitmap() throws {
        let source = makeSolidImage(width: 1024, height: 1024, color: .blue)
        let unbadged = try XCTUnwrap(BundleIconImage.make(from: source, addingLabBadge: false))
        let icon = try XCTUnwrap(BundleIconImage.make(from: source, addingLabBadge: true))
        let unbadgedBitmap = try XCTUnwrap(unbadged.representations.first as? NSBitmapImageRep)
        let bitmap = try XCTUnwrap(icon.representations.first as? NSBitmapImageRep)
        let badgeCenter = try XCTUnwrap(bitmap.colorAt(x: 413, y: 99)?.usingColorSpace(.deviceRGB))

        let changedPixels = changedPixelCount(between: unbadgedBitmap, and: bitmap)
        XCTAssertGreaterThan(changedPixels, 1)
        XCTAssertGreaterThan(badgeCenter.redComponent, badgeCenter.blueComponent)
        assertCanonicalRepresentation(in: icon)
    }

    private func makeSolidImage(width: Int, height: Int, color: NSColor) -> NSImage {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        bitmap.size = NSSize(width: width, height: height)
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = context

        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        context.flushGraphics()
        NSGraphicsContext.current = previousContext

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(bitmap)
        return image
    }

    private func changedPixelCount(between original: NSBitmapImageRep, and rendered: NSBitmapImageRep) -> Int {
        guard original.pixelsWide == rendered.pixelsWide,
              original.pixelsHigh == rendered.pixelsHigh,
              original.bitsPerPixel == rendered.bitsPerPixel,
              let originalData = original.bitmapData,
              let renderedData = rendered.bitmapData else {
            XCTFail("Expected comparable bitmap data")
            return 0
        }

        let bytesPerPixel = original.bitsPerPixel / 8
        guard bytesPerPixel > 0 else {
            XCTFail("Expected byte-addressable bitmap pixels")
            return 0
        }

        var changedPixels = 0
        for y in 0..<original.pixelsHigh {
            for x in 0..<original.pixelsWide {
                let originalOffset = y * original.bytesPerRow + x * bytesPerPixel
                let renderedOffset = y * rendered.bytesPerRow + x * bytesPerPixel
                let pixelChanged = (0..<bytesPerPixel).contains { byteIndex in
                    originalData[originalOffset + byteIndex] != renderedData[renderedOffset + byteIndex]
                }
                if pixelChanged {
                    changedPixels += 1
                }
            }
        }
        return changedPixels
    }

    private func assertCanonicalRepresentation(
        in image: NSImage,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertEqual(image.size, NSSize(width: BundleIconImage.pixelDimension, height: BundleIconImage.pixelDimension), file: file, line: line)
        XCTAssertEqual(image.representations.count, 1, file: file, line: line)

        guard let bitmap = image.representations.first as? NSBitmapImageRep else {
            XCTFail("Expected a bitmap image representation", file: file, line: line)
            return
        }
        XCTAssertEqual(bitmap.pixelsWide, BundleIconImage.pixelDimension, file: file, line: line)
        XCTAssertEqual(bitmap.pixelsHigh, BundleIconImage.pixelDimension, file: file, line: line)
    }
}
