// Renders the ForeverAddons app icon with CoreGraphics.
//
// Regenerate everything (run from the repo root):
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift App/Design/render-icon.swift
//
// Outputs:
//   App/Design/AppIcon-1024.png                          1024 px preview
//   App/ForeverAddons/Assets.xcassets/Contents.json
//   App/ForeverAddons/Assets.xcassets/AppIcon.appiconset/ every macOS size + Contents.json
//
// Concept: a gold puzzle piece (an add-on) engraved with an infinity loop
// ("forever"), on a deep night-blue/purple squircle, trimmed in old-UI gold.
// Each size is drawn from vectors at its own pixel size rather than downscaled,
// and small sizes get heavier strokes so the loop survives at 16 px.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Paths

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let designDir = scriptURL.deletingLastPathComponent()
let appDir = designDir.deletingLastPathComponent()
let catalogDir = appDir.appendingPathComponent("ForeverAddons/Assets.xcassets")
let iconSetDir = catalogDir.appendingPathComponent("AppIcon.appiconset")

// MARK: - Colors

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: sRGB,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha,
        ])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: sRGB,
        colors: stops.map(\.1) as CFArray,
        locations: stops.map(\.0))!
}

// MARK: - Geometry (1024-point design space, y grows downward)

/// macOS icon grid: 824 pt rounded square centred on a 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)

/// Superellipse approximating Apple's continuous-corner icon shape.
func squircle(in rect: CGRect, exponent n: CGFloat = 5.2) -> CGPath {
    let path = CGMutablePath()
    let cx = rect.midX, cy = rect.midY, a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * copysign(pow(abs(c), 2 / n), c)
        let y = cy + b * copysign(pow(abs(s), 2 / n), s)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Puzzle piece: rounded body, tabs on top and right, a blank on the left.
func puzzlePiece() -> CGPath {
    let body = CGRect(x: 262, y: 372, width: 420, height: 420)
    let knobR: CGFloat = 74
    let neck: CGFloat = 92

    var piece = CGPath(roundedRect: body, cornerWidth: 56, cornerHeight: 56, transform: nil)

    // Top tab.
    let topCenter = CGPoint(x: body.midX, y: body.minY - 62)
    piece = piece.union(CGPath(ellipseIn: CGRect(x: topCenter.x - knobR, y: topCenter.y - knobR, width: knobR * 2, height: knobR * 2), transform: nil))
    piece = piece.union(CGPath(rect: CGRect(x: body.midX - neck / 2, y: topCenter.y, width: neck, height: 80), transform: nil))

    // Right tab.
    let rightCenter = CGPoint(x: body.maxX + 62, y: body.midY)
    piece = piece.union(CGPath(ellipseIn: CGRect(x: rightCenter.x - knobR, y: rightCenter.y - knobR, width: knobR * 2, height: knobR * 2), transform: nil))
    piece = piece.union(CGPath(rect: CGRect(x: rightCenter.x - 80, y: body.midY - neck / 2, width: 80, height: neck), transform: nil))

    // Left blank.
    let blankR: CGFloat = 66
    let leftCenter = CGPoint(x: body.minX + 6, y: body.midY)
    piece = piece.subtracting(CGPath(ellipseIn: CGRect(x: leftCenter.x - blankR, y: leftCenter.y - blankR, width: blankR * 2, height: blankR * 2), transform: nil))

    // Optically centre the piece in the tile (its bounds skew up-right).
    let box = piece.boundingBoxOfPath
    var shift = CGAffineTransform(translationX: tile.midX - box.midX, y: tile.midY - box.midY + 6)
    return piece.copy(using: &shift)!
}

/// Lemniscate of Bernoulli centred on `center` with half-width `a`.
func infinity(center: CGPoint, a: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let steps = 400
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let d = 1 + sin(t) * sin(t)
        let p = CGPoint(x: center.x + a * cos(t) / d, y: center.y + a * 1.18 * sin(t) * cos(t) / d)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

// MARK: - Drawing

func draw(in ctx: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / 1024
    // Heavier strokes at small sizes so details survive downsampling.
    let weight: CGFloat = pixels <= 16 ? 1.9 : pixels <= 32 ? 1.25 : pixels <= 64 ? 1.15 : 1

    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    let shape = squircle(in: tile)

    // Drop shadow, as in the macOS icon template.
    ctx.saveGState()
    // Shadow offsets are in unflipped device space, so negative heights fall downward.
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale, color: rgb(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x14163A))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: purple dusk at the top fading into night blue.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x4A3391)), (0.55, rgb(0x231C5C)), (1, rgb(0x0C1030))]),
        start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY), options: [])
    // Soft halo behind the piece.
    ctx.drawRadialGradient(
        gradient([(0, rgb(0x8A6CFF, 0.38)), (1, rgb(0x8A6CFF, 0))]),
        startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 500), endRadius: 420, options: [])
    ctx.restoreGState()

    // Gold trim just inside the tile edge, plus a glassy top highlight.
    ctx.saveGState()
    ctx.addPath(squircle(in: tile.insetBy(dx: 14, dy: 14)))
    ctx.setLineWidth(10 * weight)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0xF4D58A, 0.95)), (0.5, rgb(0xB8862B, 0.75)), (1, rgb(0x6E4A16, 0.9))]),
        start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY), options: [])
    ctx.restoreGState()

    if pixels > 32 {
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.setLineWidth(6)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([(0, rgb(0xFFFFFF, 0.4)), (0.12, rgb(0xFFFFFF, 0.0))]),
            start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY), options: [])
        ctx.restoreGState()
    }

    let piece = puzzlePiece()
    let box = piece.boundingBoxOfPath

    // Piece shadow for lift.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * scale), blur: 36 * scale, color: rgb(0x05061A, 0.6))
    ctx.addPath(piece)
    ctx.setFillColor(rgb(0x8A6020))
    ctx.fillPath()
    ctx.restoreGState()

    // Gold body.
    ctx.saveGState()
    ctx.addPath(piece)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0xFFE9A8)), (0.35, rgb(0xF2C25A)), (0.75, rgb(0xC98F2E)), (1, rgb(0x9A6820))]),
        start: CGPoint(x: box.minX, y: box.minY), end: CGPoint(x: box.maxX - 80, y: box.maxY), options: [])
    // Specular sheen toward the upper left.
    ctx.drawRadialGradient(
        gradient([(0, rgb(0xFFF8E0, 0.55)), (1, rgb(0xFFF8E0, 0))]),
        startCenter: CGPoint(x: box.minX + 120, y: box.minY + 200), startRadius: 0,
        endCenter: CGPoint(x: box.minX + 120, y: box.minY + 200), endRadius: 260, options: [])
    // Inner highlight along the upper edge: the piece offset downward, subtracted.
    var down = CGAffineTransform(translationX: 0, y: 10)
    let highlight = piece.subtracting(piece.copy(using: &down)!)
    ctx.addPath(highlight)
    ctx.setFillColor(rgb(0xFFF6D6, 0.6))
    ctx.fillPath()
    var up = CGAffineTransform(translationX: 0, y: -12)
    let lowlight = piece.subtracting(piece.copy(using: &up)!)
    ctx.addPath(lowlight)
    ctx.setFillColor(rgb(0x5E3C10, 0.55))
    ctx.fillPath()
    ctx.restoreGState()

    // Dark rim.
    ctx.addPath(piece)
    ctx.setStrokeColor(rgb(0x4A2E0C, 0.9))
    ctx.setLineWidth(6 * weight)
    ctx.strokePath()

    // The loop turns to mush at 16 px; the bare piece reads better there.
    guard pixels > 16 else { return }

    // Engraved infinity loop, centred on the body (left of the right tab).
    // Nudged right of the body's centre to clear the left blank.
    let loopCenter = CGPoint(x: box.minX + 246, y: box.maxY - 210)
    let loop = infinity(center: loopCenter, a: 124)
    let loopWidth: CGFloat = 44 * weight

    // Lower-edge light catch, then the cut itself.
    ctx.saveGState()
    ctx.translateBy(x: 0, y: 5)
    ctx.addPath(loop)
    ctx.setLineWidth(loopWidth)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(rgb(0xFFF1C4, 0.9))
    ctx.strokePath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(loop)
    ctx.setLineWidth(loopWidth)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x120E30)), (1, rgb(0x2C2366))]),
        start: CGPoint(x: 0, y: loopCenter.y - 90), end: CGPoint(x: 0, y: loopCenter.y + 90), options: [])
    ctx.restoreGState()
}

// MARK: - Output

func renderPNG(pixels: Int, to url: URL) throws {
    guard
        let ctx = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw NSError(domain: "render-icon", code: 1) }
    draw(in: ctx, pixels: pixels)
    guard let image = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "render-icon", code: 2) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "render-icon", code: 3) }
}

let fm = FileManager.default
try fm.createDirectory(at: iconSetDir, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = "icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"
        try renderPNG(pixels: points * factor, to: iconSetDir.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(factor)x", "size": "\(points)x\(points)"])
    }
}

func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try (data + Data("\n".utf8)).write(to: url)
}

let info = ["author": "xcode", "version": 1] as [String: Any]
try writeJSON(["images": images, "info": info], to: iconSetDir.appendingPathComponent("Contents.json"))
try writeJSON(["info": info], to: catalogDir.appendingPathComponent("Contents.json"))
try renderPNG(pixels: 1024, to: designDir.appendingPathComponent("AppIcon-1024.png"))

print("Wrote \(images.count) icon images to \(iconSetDir.path)")
