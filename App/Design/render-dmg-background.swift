// Renders the background of the Reload disk image window: a soft parchment wash with a
// gold arrow from the app to the Applications folder and a one-line instruction.
//
// Regenerate (run from the repo root):
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift App/Design/render-dmg-background.swift
//
// Outputs App/Design/dmg-background.tiff, holding 1x and 2x images so Retina screens get a
// sharp copy. The icon centres it draws around must match scripts/dmg-settings.py.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let designDir = scriptURL.deletingLastPathComponent()

// Points, top-left origin like Finder. Keep in step with dmg-settings.py.
let size = CGSize(width: 660, height: 400)
let appCentre = CGPoint(x: 170, y: 190)
let applicationsCentre = CGPoint(x: 490, y: 190)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(scale: CGFloat) -> CGImage {
    let width = Int(size.width * scale), height = Int(size.height * scale)
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Flip to top-left so the coordinates read like Finder's.
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: scale, y: -scale)

    let wash = CGGradient(colorsSpace: nil, colors: [rgb(0xFBF7EE), rgb(0xF1E8D6)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(wash, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

    // The arrow sits between the two 128 pt icons, a little above their centres.
    let y = appCentre.y - 4
    let start = CGPoint(x: appCentre.x + 92, y: y)
    let tip = CGPoint(x: applicationsCentre.x - 92, y: y)
    let gold = rgb(0xB8862F)
    ctx.setStrokeColor(gold)
    ctx.setLineWidth(7)
    ctx.setLineCap(.round)
    ctx.move(to: start)
    ctx.addLine(to: CGPoint(x: tip.x - 14, y: y))
    ctx.strokePath()
    ctx.setFillColor(gold)
    ctx.move(to: tip)
    ctx.addLine(to: CGPoint(x: tip.x - 28, y: y - 18))
    ctx.addLine(to: CGPoint(x: tip.x - 28, y: y + 18))
    ctx.closePath()
    ctx.fillPath()

    drawCentred("Drag Reload into Applications to install", at: CGPoint(x: size.width / 2, y: 330),
                size: 15, color: rgb(0x5C4A2E), in: ctx)
    return ctx.makeImage()!
}

func drawCentred(_ string: String, at point: CGPoint, size fontSize: CGFloat, color: CGColor, in ctx: CGContext) {
    let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)!
    let attributed = NSAttributedString(string: string, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.saveGState()
    // Core Text draws upright in an unflipped space.
    ctx.translateBy(x: point.x - width / 2, y: point.y)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

let output = designDir.appendingPathComponent("dmg-background.tiff")
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.tiff.identifier as CFString, 2, nil)!
for scale in [1.0, 2.0] {
    // 72 dpi for 1x and 144 for 2x is how Finder tells the representations apart.
    let dpi = 72 * scale
    CGImageDestinationAddImage(destination, render(scale: scale), [
        kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5],
    ] as CFDictionary)
}
guard CGImageDestinationFinalize(destination) else { fatalError("couldn't write \(output.path)") }
print("wrote \(output.path)")
