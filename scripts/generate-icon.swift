import AppKit
import CoreGraphics
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources/Brand", isDirectory: true)

func page(_ name: String) throws -> CGPDFPage {
    let url = assets.appendingPathComponent(name).appendingPathExtension("pdf")
    guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return page
}

func draw(_ page: CGPDFPage, in rect: CGRect, using context: CGContext) {
    let bounds = page.getBoxRect(.mediaBox)
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.minY)
    context.scaleBy(x: rect.width / bounds.width, y: rect.height / bounds.height)
    context.drawPDFPage(page)
    context.restoreGState()
}

// Compose the original vector glyph exports without the background. Coordinates
// retain their relative positions in the design, cropped to the visible mark.
var markBounds = CGRect(x: 0, y: 0, width: 56.43115234375, height: 57)
let markURL = assets.appendingPathComponent("Mark.pdf")
guard let markContext = CGContext(markURL as CFURL, mediaBox: &markBounds, nil) else {
    throw CocoaError(.fileWriteUnknown)
}
markContext.beginPDFPage(nil)
draw(try page("Letter"), in: CGRect(x: 0, y: 9.52685546875,
                                   width: 32.04931640625, height: 36.9052734375), using: markContext)
draw(try page("Cursor"), in: CGRect(x: 36.43115234375, y: 0, width: 20, height: 57), using: markContext)
markContext.endPDFPage()
markContext.closePDF()

let icon = try page("Icon")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let side = CGFloat(pixels)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CocoaError(.fileWriteUnknown)
        }
        draw(icon, in: CGRect(x: side * 0.05, y: side * 0.05, width: side * 0.9, height: side * 0.9),
             using: context.cgContext)
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: directory.appendingPathComponent(name))
    }
}
