// Renders the ForeverAddons app icon and its alternate icons with CoreGraphics.
//
// Regenerate everything (run from the repo root):
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift App/Design/render-icon.swift
//
// Outputs:
//   App/Design/AppIcon-1024.png                          1024 px preview
//   App/ForeverAddons/Assets.xcassets/Contents.json
//   App/ForeverAddons/Assets.xcassets/AppIcon.appiconset/ every macOS size + Contents.json
//   App/ForeverAddons/Assets.xcassets/AltIcon-*.imageset/ one 1024 px PNG each (universal 1x)
//   App/Design/alt-previews/AltIcon-*.png                256 px previews
//   App/Design/alt-icons-sheet.png                       all alternates side by side
//
// Main icon: a gold puzzle piece (an add-on) engraved with an infinity loop
// ("forever"), on a deep night-blue/purple squircle, trimmed in old-UI gold.
// Each size is drawn from vectors at its own pixel size rather than downscaled,
// and small sizes get heavier strokes so the loop survives at 16 px.
//
// Alternates share the tile, trim, solid-material and engraving helpers so
// they read as one family. The asset names are a contract with the Settings
// icon picker; don't rename them.
//   AltIcon-Classic   the main icon, from the same drawing code
//   AltIcon-Rune      hewn grey rune stone ringed with carved marks; the
//                     infinity glows arcane blue in its centre
//   AltIcon-Scroll    parchment quest scroll on crimson, closed by a red wax
//                     seal embossed with the infinity mark, ribbon tails below
//   AltIcon-Gilded    the gold puzzle on ivory with a deep bronze loop, the
//                     light variant
// The alternates are only shipped at 1024 px (the system downsamples), so
// their strokes are drawn a little heavier to stay legible at 32 px.

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
let previewDir = designDir.appendingPathComponent("alt-previews")

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

/// A colour fading to fully transparent, for halos and sheens.
func fade(_ color: CGColor) -> CGGradient {
    gradient([(0, color), (1, color.copy(alpha: 0)!)])
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

/// A closed blob whose radius wobbles by `harmonics` (amplitude, frequency, phase).
func wobblyCircle(center: CGPoint, radius: CGFloat, harmonics: [(CGFloat, CGFloat, CGFloat)]) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let r = radius * (1 + harmonics.reduce(0) { $0 + $1.0 * sin($1.1 * t + $1.2) })
        let p = CGPoint(x: center.x + r * cos(t), y: center.y + r * sin(t))
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

func transformed(_ path: CGPath, scale s: CGFloat, from: CGPoint, to: CGPoint) -> CGPath {
    var t = CGAffineTransform(translationX: to.x, y: to.y).scaledBy(x: s, y: s).translatedBy(x: -from.x, y: -from.y)
    return path.copy(using: &t)!
}

// MARK: - Shared drawing helpers

/// Flips into the 1024-point design space and returns the stroke weight for this size.
func begin(_ ctx: CGContext, pixels: Int) -> (scale: CGFloat, weight: CGFloat) {
    let scale = CGFloat(pixels) / 1024
    // Heavier strokes at small sizes so details survive downsampling.
    let weight: CGFloat = pixels <= 16 ? 1.9 : pixels <= 32 ? 1.25 : pixels <= 64 ? 1.15 : 1
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return (scale, weight)
}

struct TileStyle {
    var base: CGColor
    var background: [(CGFloat, CGColor)]
    var halo: CGColor?
    var haloCenter = CGPoint(x: 512, y: 500)
    var haloRadius: CGFloat = 420
    var trim: [(CGFloat, CGColor)]
    var trimWidth: CGFloat = 10
    var shadowAlpha: CGFloat = 0.35
    var gloss: CGFloat = 0.4
}

/// The squircle with drop shadow, background, halo, inner trim and top gloss.
func drawTile(_ ctx: CGContext, _ style: TileStyle, scale: CGFloat, weight: CGFloat, pixels: Int) {
    let shape = squircle(in: tile)

    // Drop shadow, as in the macOS icon template.
    ctx.saveGState()
    // Shadow offsets are in unflipped device space, so negative heights fall downward.
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale, color: rgb(0x000000, style.shadowAlpha))
    ctx.addPath(shape)
    ctx.setFillColor(style.base)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient(style.background),
        start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY), options: [])
    if let halo = style.halo {
        ctx.drawRadialGradient(
            fade(halo),
            startCenter: style.haloCenter, startRadius: 0,
            endCenter: style.haloCenter, endRadius: style.haloRadius, options: [])
    }
    ctx.restoreGState()

    // Trim just inside the tile edge.
    ctx.saveGState()
    ctx.addPath(squircle(in: tile.insetBy(dx: 14, dy: 14)))
    ctx.setLineWidth(style.trimWidth * weight)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient(style.trim),
        start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY), options: [])
    ctx.restoreGState()

    // Glassy top highlight on the outer edge.
    if pixels > 32 {
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.setLineWidth(6)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([(0, rgb(0xFFFFFF, style.gloss)), (0.12, rgb(0xFFFFFF, 0.0))]),
            start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY), options: [])
        ctx.restoreGState()
    }
}

/// How a raised solid (puzzle piece, stone, seal) is lit.
struct Material {
    var shadow: CGColor
    var shadowDrop: CGFloat = 18
    var shadowBlur: CGFloat = 36
    var base: CGColor
    var body: [(CGFloat, CGColor)]
    var bodyEndInset: CGFloat = 80
    var sheen: CGColor?
    var sheenOffset = CGPoint(x: 120, y: 200)
    var sheenRadius: CGFloat = 260
    var highlight: CGColor
    var highlightDepth: CGFloat = 10
    var lowlight: CGColor
    var lowlightDepth: CGFloat = 12
    var rim: CGColor
    var rimWidth: CGFloat = 6
}

/// Fills `path` as a lifted solid: cast shadow, diagonal body gradient,
/// specular sheen, bevel light on top edges and shade on bottom edges, rim.
func drawSolid(_ ctx: CGContext, _ path: CGPath, _ m: Material, scale: CGFloat, weight: CGFloat) {
    let box = path.boundingBoxOfPath

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -m.shadowDrop * scale), blur: m.shadowBlur * scale, color: m.shadow)
    ctx.addPath(path)
    ctx.setFillColor(m.base)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient(m.body),
        start: CGPoint(x: box.minX, y: box.minY), end: CGPoint(x: box.maxX - m.bodyEndInset, y: box.maxY), options: [])
    if let sheen = m.sheen {
        let c = CGPoint(x: box.minX + m.sheenOffset.x, y: box.minY + m.sheenOffset.y)
        ctx.drawRadialGradient(fade(sheen), startCenter: c, startRadius: 0, endCenter: c, endRadius: m.sheenRadius, options: [])
    }
    // Bevel: the shape minus itself shifted down leaves a sliver along top edges.
    var down = CGAffineTransform(translationX: 0, y: m.highlightDepth)
    ctx.addPath(path.subtracting(path.copy(using: &down)!))
    ctx.setFillColor(m.highlight)
    ctx.fillPath()
    var up = CGAffineTransform(translationX: 0, y: -m.lowlightDepth)
    ctx.addPath(path.subtracting(path.copy(using: &up)!))
    ctx.setFillColor(m.lowlight)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.addPath(path)
    ctx.setStrokeColor(m.rim)
    ctx.setLineWidth(m.rimWidth * weight)
    ctx.strokePath()
}

/// A groove cut along `path`.
struct Engraving {
    var width: CGFloat
    var lightCatch: CGColor?
    var catchOffset: CGFloat = 5
    var fill: [(CGFloat, CGColor)]
    /// Half-height of the fill gradient; must cover the stroke or its edges go unpainted.
    var span: CGFloat = 90
    var roundCaps = false
}

/// Strokes a cut: a light catch on its lower lip, then the shaded groove.
func engrave(_ ctx: CGContext, _ path: CGPath, _ e: Engraving, weight: CGFloat) {
    let midY = path.boundingBoxOfPath.midY
    let width = e.width * weight

    if let light = e.lightCatch {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: e.catchOffset)
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setLineJoin(.round)
        if e.roundCaps { ctx.setLineCap(.round) }
        ctx.setStrokeColor(light)
        ctx.strokePath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.setLineJoin(.round)
    if e.roundCaps { ctx.setLineCap(.round) }
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient(e.fill),
        start: CGPoint(x: 0, y: midY - e.span), end: CGPoint(x: 0, y: midY + e.span), options: [])
    ctx.restoreGState()
}

/// Strokes `path` as light: a bloom of widening translucent strokes, then a bright core.
/// Built from strokes rather than a blurred shadow, which CoreGraphics clips
/// to the stroke's bounding box.
func glow(_ ctx: CGContext, _ path: CGPath, width: CGFloat, color: CGColor, core: CGColor, bloom: CGFloat) {
    ctx.saveGState()
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    let rings = 10
    for i in stride(from: rings, through: 1, by: -1) {
        let t = CGFloat(i) / CGFloat(rings)
        ctx.addPath(path)
        ctx.setLineWidth(width + bloom * t)
        ctx.setStrokeColor(color.copy(alpha: color.alpha * 0.16 * (1 - t * 0.6))!)
        ctx.strokePath()
    }
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.setStrokeColor(color)
    ctx.strokePath()
    ctx.addPath(path)
    ctx.setLineWidth(width * 0.45)
    ctx.setStrokeColor(core)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Shared palettes

let goldTrim: [(CGFloat, CGColor)] = [(0, rgb(0xF4D58A, 0.95)), (0.5, rgb(0xB8862B, 0.75)), (1, rgb(0x6E4A16, 0.9))]

let gold = Material(
    shadow: rgb(0x05061A, 0.6),
    base: rgb(0x8A6020),
    body: [(0, rgb(0xFFE9A8)), (0.35, rgb(0xF2C25A)), (0.75, rgb(0xC98F2E)), (1, rgb(0x9A6820))],
    sheen: rgb(0xFFF8E0, 0.55),
    highlight: rgb(0xFFF6D6, 0.6),
    lowlight: rgb(0x5E3C10, 0.55),
    rim: rgb(0x4A2E0C, 0.9))

/// The main motif: a solid puzzle piece with an engraved infinity loop.
func drawPuzzleMotif(_ ctx: CGContext, piece m: Material, loop e: Engraving, scale: CGFloat, weight: CGFloat, pixels: Int) {
    let piece = puzzlePiece()
    let box = piece.boundingBoxOfPath
    drawSolid(ctx, piece, m, scale: scale, weight: weight)

    // The loop turns to mush at 16 px; the bare piece reads better there.
    guard pixels > 16 else { return }

    // Centred on the body (left of the right tab), nudged right to clear the left blank.
    let loopCenter = CGPoint(x: box.minX + 246, y: box.maxY - 210)
    engrave(ctx, infinity(center: loopCenter, a: 124), e, weight: weight)
}

// MARK: - Classic (the main icon)

func drawClassic(in ctx: CGContext, pixels: Int) {
    let (scale, weight) = begin(ctx, pixels: pixels)
    drawTile(
        ctx,
        TileStyle(
            base: rgb(0x14163A),
            // Purple dusk at the top fading into night blue.
            background: [(0, rgb(0x4A3391)), (0.55, rgb(0x231C5C)), (1, rgb(0x0C1030))],
            halo: rgb(0x8A6CFF, 0.38),
            trim: goldTrim),
        scale: scale, weight: weight, pixels: pixels)
    drawPuzzleMotif(
        ctx, piece: gold,
        loop: Engraving(width: 44, lightCatch: rgb(0xFFF1C4, 0.9), fill: [(0, rgb(0x120E30)), (1, rgb(0x2C2366))]),
        scale: scale, weight: weight, pixels: pixels)
}

// MARK: - Rune

/// Invented angular marks for the stone's ring, in a unit box (y down).
/// Abstract on purpose: they suggest runes without spelling anything.
let runeMarks: [[[CGPoint]]] = [
    // Stave with two rising branches.
    [[.init(x: 0, y: -1), .init(x: 0, y: 1)], [.init(x: 0, y: -0.45), .init(x: 0.55, y: -0.95)], [.init(x: 0, y: 0.05), .init(x: 0.55, y: -0.45)]],
    // Diamond.
    [[.init(x: 0, y: -1), .init(x: 0.55, y: 0), .init(x: 0, y: 1), .init(x: -0.55, y: 0), .init(x: 0, y: -1)]],
    // Stave crossed by a slant.
    [[.init(x: 0, y: -1), .init(x: 0, y: 1)], [.init(x: -0.5, y: -0.45), .init(x: 0.5, y: 0.15)]],
    // Bowtie between two staves.
    [[.init(x: -0.5, y: -1), .init(x: -0.5, y: 1), .init(x: 0.5, y: -1), .init(x: 0.5, y: 1), .init(x: -0.5, y: -1)]],
    // Stave with an arrowhead.
    [[.init(x: 0, y: -1), .init(x: 0, y: 1)], [.init(x: -0.55, y: -0.4), .init(x: 0, y: -1), .init(x: 0.55, y: -0.4)]],
    // Stave with a hooked foot.
    [[.init(x: 0, y: -1), .init(x: 0, y: 1)], [.init(x: 0, y: 0.25), .init(x: 0.5, y: 0.6), .init(x: 0, y: 1)]],
]

func runeRing(center: CGPoint, radius: CGFloat, count: Int, size: CGFloat) -> CGPath {
    let path = CGMutablePath()
    for i in 0..<count {
        let theta = CGFloat(i) / CGFloat(count) * 2 * .pi
        let mark = runeMarks[(i * 5) % runeMarks.count]
        let t = CGAffineTransform(translationX: center.x + radius * sin(theta), y: center.y - radius * cos(theta))
            .rotated(by: theta).scaledBy(x: size, y: size)
        for stroke in mark {
            path.addLines(between: stroke, transform: t)
        }
    }
    return path
}

func drawRune(in ctx: CGContext, pixels: Int) {
    let (scale, weight) = begin(ctx, pixels: pixels)
    let arcane = rgb(0x4FB4FF)
    drawTile(
        ctx,
        TileStyle(
            base: rgb(0x1A1E25),
            background: [(0, rgb(0x5A6472)), (0.5, rgb(0x2F353F)), (1, rgb(0x14171C))],
            halo: rgb(0x3D9BFF, 0.42),
            haloCenter: CGPoint(x: 512, y: 520),
            haloRadius: 440,
            trim: [(0, rgb(0xD6E8FF, 0.95)), (0.5, rgb(0x7F93AD, 0.75)), (1, rgb(0x343E4C, 0.9))]),
        scale: scale, weight: weight, pixels: pixels)

    let center = CGPoint(x: 512, y: 514)
    let stone = wobblyCircle(center: center, radius: 318, harmonics: [(0.022, 3, 0.4), (0.014, 7, 1.3), (0.008, 11, 2.1)])
    drawSolid(
        ctx, stone,
        Material(
            shadow: rgb(0x020409, 0.7), shadowDrop: 20, shadowBlur: 40,
            base: rgb(0x4A515C),
            body: [(0, rgb(0xB9C1CB)), (0.4, rgb(0x8D96A2)), (0.8, rgb(0x5E6672)), (1, rgb(0x474E59))],
            bodyEndInset: 160,
            sheen: rgb(0xF2F6FA, 0.35), sheenOffset: CGPoint(x: 190, y: 150), sheenRadius: 300,
            highlight: rgb(0xEEF3F8, 0.55), highlightDepth: 12,
            lowlight: rgb(0x1B1F26, 0.6), lowlightDepth: 14,
            rim: rgb(0x1C2129, 0.95), rimWidth: 7),
        scale: scale, weight: weight)

    // Faint arcane light pooling in the stone's face, over a seeded grain so it
    // reads as stone rather than brushed metal.
    ctx.saveGState()
    ctx.addPath(stone)
    ctx.clip()
    var seed: UInt64 = 0x5EED
    func random() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(seed >> 33) / CGFloat(1 << 31)
    }
    for _ in 0..<1600 {
        let p = CGPoint(x: center.x - 330 + random() * 660, y: center.y - 330 + random() * 660)
        let r = 1.2 + random() * 2.6
        ctx.setFillColor(random() < 0.5 ? rgb(0x1A1E25, 0.14) : rgb(0xFFFFFF, 0.1))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }
    ctx.drawRadialGradient(fade(rgb(0x6CC4FF, 0.3)), startCenter: center, startRadius: 0, endCenter: center, endRadius: 230, options: [])
    ctx.restoreGState()

    let groove = Engraving(width: 13, lightCatch: rgb(0xE4EAF1, 0.55), catchOffset: 4, fill: [(0, rgb(0x1A1E25)), (1, rgb(0x343B46))], span: 260)
    engrave(ctx, CGPath(ellipseIn: CGRect(x: center.x - 268, y: center.y - 268, width: 536, height: 536), transform: nil), groove, weight: weight)
    engrave(ctx, CGPath(ellipseIn: CGRect(x: center.x - 190, y: center.y - 190, width: 380, height: 380), transform: nil), groove, weight: weight)

    let marks = runeRing(center: center, radius: 229, count: 12, size: 21)
    engrave(ctx, marks, Engraving(width: 11, lightCatch: rgb(0xE4EAF1, 0.45), catchOffset: 3, fill: [(0, rgb(0x1E2A3A)), (1, rgb(0x2A3E58))], span: 260, roundCaps: true), weight: weight)
    glow(ctx, marks, width: 5, color: arcane.copy(alpha: 0.6)!, core: rgb(0xCFEBFF, 0.85), bloom: 14)

    let loop = infinity(center: CGPoint(x: center.x, y: center.y + 2), a: 150)
    engrave(ctx, loop, Engraving(width: 60, lightCatch: rgb(0xE4EAF1, 0.6), fill: [(0, rgb(0x0E1622)), (1, rgb(0x1C2A3E))], span: 100), weight: weight)
    glow(ctx, loop, width: 32 * weight, color: arcane, core: rgb(0xEAF8FF), bloom: 70)
}

// MARK: - Scroll

let parchment: [(CGFloat, CGColor)] = [(0, rgb(0xFCF1D4)), (0.4, rgb(0xF1DDAC)), (0.8, rgb(0xD9BC80)), (1, rgb(0xB8955A))]

/// A rolled end of the scroll: a lit cylinder with a curl at each end.
func drawRoll(_ ctx: CGContext, _ rect: CGRect, scale: CGFloat, weight: CGFloat) {
    let h = rect.height
    let roll = CGPath(roundedRect: rect, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 24 * scale, color: rgb(0x2A0306, 0.55))
    ctx.addPath(roll)
    ctx.setFillColor(rgb(0xB8955A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(roll)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0xE9D29C)), (0.22, rgb(0xFFF6DC)), (0.55, rgb(0xEBD39E)), (1, rgb(0x9E7B44))]),
        start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
    ctx.restoreGState()

    // Curls: the rolled-up layers seen end-on.
    for x in [rect.minX + h * 0.36, rect.maxX - h * 0.36] {
        let curl = CGRect(x: x - h * 0.2, y: rect.midY - h * 0.36, width: h * 0.4, height: h * 0.72)
        ctx.addEllipse(in: curl)
        ctx.setFillColor(rgb(0xC9A466))
        ctx.fillPath()
        ctx.addEllipse(in: curl)
        ctx.setStrokeColor(rgb(0x6B4C22, 0.9))
        ctx.setLineWidth(4 * weight)
        ctx.strokePath()
        ctx.addEllipse(in: curl.insetBy(dx: h * 0.08, dy: h * 0.15))
        ctx.setStrokeColor(rgb(0x6B4C22, 0.75))
        ctx.setLineWidth(4 * weight)
        ctx.strokePath()
    }

    ctx.addPath(roll)
    ctx.setStrokeColor(rgb(0x5E4019, 0.9))
    ctx.setLineWidth(6 * weight)
    ctx.strokePath()
}

/// A ribbon tail hanging from `top` at `angle` (radians from straight down), swallowtail cut.
func ribbonTail(top: CGPoint, angle: CGFloat, length: CGFloat, width: CGFloat) -> CGPath {
    let d = CGPoint(x: sin(angle), y: cos(angle))
    let n = CGPoint(x: cos(angle), y: -sin(angle))
    func p(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
        CGPoint(x: top.x + d.x * along + n.x * across, y: top.y + d.y * along + n.y * across)
    }
    let path = CGMutablePath()
    path.addLines(between: [p(0, -width / 2), p(0, width / 2), p(length, width / 2), p(length - width * 0.55, 0), p(length, -width / 2)])
    path.closeSubpath()
    return path
}

func drawScroll(in ctx: CGContext, pixels: Int) {
    let (scale, weight) = begin(ctx, pixels: pixels)
    drawTile(
        ctx,
        TileStyle(
            base: rgb(0x3A070D),
            background: [(0, rgb(0xB0283A)), (0.55, rgb(0x6E1120)), (1, rgb(0x33060E))],
            halo: rgb(0xFF9A6A, 0.28),
            trim: goldTrim),
        scale: scale, weight: weight, pixels: pixels)

    let topRoll = CGRect(x: 268, y: 206, width: 488, height: 100)
    let bottomRoll = CGRect(x: 268, y: 724, width: 488, height: 100)
    let sheetRect = CGRect(x: 312, y: topRoll.midY, width: 400, height: bottomRoll.midY - topRoll.midY)
    let sheet = CGPath(rect: sheetRect, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16 * scale), blur: 34 * scale, color: rgb(0x2A0306, 0.6))
    ctx.addPath(sheet)
    ctx.setFillColor(rgb(0xD9BC80))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(sheet)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient(parchment),
        start: CGPoint(x: sheetRect.minX, y: sheetRect.minY), end: CGPoint(x: sheetRect.maxX, y: sheetRect.maxY), options: [])
    // The paper darkens where it curves into each roll.
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x7A5526, 0.45)), (0.12, rgb(0x7A5526, 0)), (0.88, rgb(0x7A5526, 0)), (1, rgb(0x7A5526, 0.45))]),
        start: CGPoint(x: 0, y: sheetRect.minY), end: CGPoint(x: 0, y: sheetRect.maxY), options: [])
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x7A5526, 0.25)), (0.1, rgb(0x7A5526, 0)), (0.9, rgb(0x7A5526, 0)), (1, rgb(0x7A5526, 0.3))]),
        start: CGPoint(x: sheetRect.minX, y: 0), end: CGPoint(x: sheetRect.maxX, y: 0), options: [])
    // Faded ruled lines hint at a written quest without any actual text.
    ctx.setStrokeColor(rgb(0x7A5526, 0.32))
    ctx.setLineCap(.round)
    ctx.setLineWidth(10 * weight)
    for (y, inset) in [(CGFloat(368), CGFloat(56)), (410, 56), (452, 96)] {
        ctx.move(to: CGPoint(x: sheetRect.minX + 56, y: y))
        ctx.addLine(to: CGPoint(x: sheetRect.maxX - inset, y: y))
    }
    ctx.strokePath()
    ctx.restoreGState()

    ctx.addPath(sheet)
    ctx.setStrokeColor(rgb(0x6B4C22, 0.6))
    ctx.setLineWidth(4 * weight)
    ctx.strokePath()

    drawRoll(ctx, topRoll, scale: scale, weight: weight)
    drawRoll(ctx, bottomRoll, scale: scale, weight: weight)

    let sealCenter = CGPoint(x: 512, y: 580)
    let ribbon = Material(
        shadow: rgb(0x2A0306, 0.5), shadowDrop: 8, shadowBlur: 14,
        base: rgb(0x7A0E18),
        body: [(0, rgb(0xD23A44)), (0.5, rgb(0xA3192A)), (1, rgb(0x6A0A16))],
        bodyEndInset: 0,
        highlight: rgb(0xFF9AA0, 0.5), highlightDepth: 5,
        lowlight: rgb(0x3A0408, 0.5), lowlightDepth: 6,
        rim: rgb(0x3A0408, 0.9), rimWidth: 4)
    drawSolid(ctx, ribbonTail(top: sealCenter, angle: 0.42, length: 250, width: 70), ribbon, scale: scale, weight: weight)
    drawSolid(ctx, ribbonTail(top: sealCenter, angle: -0.30, length: 262, width: 70), ribbon, scale: scale, weight: weight)

    let seal = wobblyCircle(center: sealCenter, radius: 132, harmonics: [(0.035, 8, 0), (0.02, 13, 0.7), (0.012, 5, 2)])
    drawSolid(
        ctx, seal,
        Material(
            shadow: rgb(0x2A0306, 0.6), shadowDrop: 12, shadowBlur: 24,
            base: rgb(0x7E0E16),
            body: [(0, rgb(0xF0605E)), (0.4, rgb(0xC42430)), (0.8, rgb(0x8C1220)), (1, rgb(0x5E0812))],
            bodyEndInset: 40,
            sheen: rgb(0xFFC2B8, 0.5), sheenOffset: CGPoint(x: 80, y: 70), sheenRadius: 120,
            highlight: rgb(0xFFB0A8, 0.6), highlightDepth: 8,
            lowlight: rgb(0x3A0408, 0.6), lowlightDepth: 10,
            rim: rgb(0x3A0408, 0.9), rimWidth: 5),
        scale: scale, weight: weight)

    // The stamp pressed into the wax: a sunken ring and loop.
    engrave(
        ctx, CGPath(ellipseIn: CGRect(x: sealCenter.x - 100, y: sealCenter.y - 100, width: 200, height: 200), transform: nil),
        Engraving(width: 9, lightCatch: rgb(0xFF9C94, 0.6), catchOffset: 3, fill: [(0, rgb(0x4E060C)), (1, rgb(0x7A0E18))], span: 100),
        weight: weight)
    let loop = infinity(center: CGPoint(x: sealCenter.x, y: sealCenter.y + 2), a: 80)
    engrave(
        ctx, loop,
        Engraving(width: 30, lightCatch: rgb(0xFFB8AE, 0.85), catchOffset: 5, fill: [(0, rgb(0x2E0206)), (1, rgb(0x5E0810))], span: 56),
        weight: weight)
}

// MARK: - Gilded

func drawGilded(in ctx: CGContext, pixels: Int) {
    let (scale, weight) = begin(ctx, pixels: pixels)
    drawTile(
        ctx,
        TileStyle(
            base: rgb(0xE6D6B2),
            background: [(0, rgb(0xFFFCF3)), (0.55, rgb(0xF6EDD8)), (1, rgb(0xE4D2AA))],
            halo: rgb(0xFFFFFF, 0.7),
            haloCenter: CGPoint(x: 512, y: 440),
            trim: [(0, rgb(0xE8C26A, 0.95)), (0.5, rgb(0xB8862B, 0.85)), (1, rgb(0x7A5418, 0.9))],
            shadowAlpha: 0.3,
            gloss: 0.7),
        scale: scale, weight: weight, pixels: pixels)
    var piece = gold
    piece.shadow = rgb(0x6B4A1A, 0.45)
    piece.rim = rgb(0x6A4512, 0.9)
    drawPuzzleMotif(
        ctx, piece: piece,
        loop: Engraving(width: 48, lightCatch: rgb(0xFFF1C4, 0.95), fill: [(0, rgb(0x4A2C08)), (1, rgb(0x7A5016))]),
        scale: scale, weight: weight, pixels: pixels)
}

// MARK: - Output

func makeContext(width: Int, height: Int) throws -> CGContext {
    guard
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw NSError(domain: "render-icon", code: 1) }
    return ctx
}

func writePNG(_ ctx: CGContext, to url: URL) throws {
    guard let image = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "render-icon", code: 2) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "render-icon", code: 3) }
}

typealias Painter = (CGContext, Int) -> Void

func renderPNG(pixels: Int, to url: URL, _ paint: Painter = drawClassic) throws {
    let ctx = try makeContext(width: pixels, height: pixels)
    paint(ctx, pixels)
    try writePNG(ctx, to: url)
}

func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try (data + Data("\n".utf8)).write(to: url)
}

let fm = FileManager.default
let info = ["author": "xcode", "version": 1] as [String: Any]

// Main icon.
try fm.createDirectory(at: iconSetDir, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = "icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"
        try renderPNG(pixels: points * factor, to: iconSetDir.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(factor)x", "size": "\(points)x\(points)"])
    }
}
try writeJSON(["images": images, "info": info], to: iconSetDir.appendingPathComponent("Contents.json"))
try writeJSON(["info": info], to: catalogDir.appendingPathComponent("Contents.json"))
try renderPNG(pixels: 1024, to: designDir.appendingPathComponent("AppIcon-1024.png"))
print("Wrote \(images.count) icon images to \(iconSetDir.path)")

// Alternate icons.
let alternates: [(String, Painter)] = [
    ("AltIcon-Classic", drawClassic),
    ("AltIcon-Rune", drawRune),
    ("AltIcon-Scroll", drawScroll),
    ("AltIcon-Gilded", drawGilded),
]
try fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
for (name, paint) in alternates {
    let setDir = catalogDir.appendingPathComponent("\(name).imageset")
    try fm.createDirectory(at: setDir, withIntermediateDirectories: true)
    try renderPNG(pixels: 1024, to: setDir.appendingPathComponent("\(name).png"), paint)
    try writeJSON(
        ["images": [["filename": "\(name).png", "idiom": "universal", "scale": "1x"]], "info": info],
        to: setDir.appendingPathComponent("Contents.json"))
    try renderPNG(pixels: 256, to: previewDir.appendingPathComponent("\(name).png"), paint)
}

// Contact sheet: every alternate at 256 px on a neutral grey that flatters light and dark tiles.
let cell = 256, gap = 32
let sheet = try makeContext(width: alternates.count * cell + (alternates.count + 1) * gap, height: cell + 2 * gap)
sheet.setFillColor(rgb(0xC9CBD1))
sheet.fill(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
for (index, (_, paint)) in alternates.enumerated() {
    sheet.saveGState()
    sheet.translateBy(x: CGFloat(gap + index * (cell + gap)), y: CGFloat(gap))
    paint(sheet, cell)
    sheet.restoreGState()
}
try writePNG(sheet, to: designDir.appendingPathComponent("alt-icons-sheet.png"))
print("Wrote \(alternates.count) alternate icons, previews and contact sheet")
