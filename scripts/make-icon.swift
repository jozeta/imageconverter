#!/usr/bin/env swift
// Draws the imageconverter app icon (1024 × 1024 PNG) with Core Graphics.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.png
//
// Layout follows Apple's macOS icon grid: an 824 px rounded-square body centred on the
// 1024 canvas (100 px margin), continuous corners, a soft drop shadow inside the canvas.
// Colours come from the Låda Glass tokens (dark palette, Fjord / Frost Cyan accents).

import AppKit
import CoreGraphics

let size: CGFloat = 1024

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let fjord: UInt32 = 0x5A93C4
let frostCyan: UInt32 = 0x88C0D0
let birchGold: UInt32 = 0xE1BC6D
let elevated: UInt32 = 0x252930
let backdrop: UInt32 = 0x11151B
let ink: UInt32 = 0x0F1217
let paper: UInt32 = 0xECEEEF

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil) else { return }
    ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// A rounded rectangle with continuous corners. Each corner is a quarter superellipse
/// (exponent 5, close to Apple's icon shape) spanning `radius * 1.5`, joined by straight edges.
func continuousRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let extent = min(radius * 1.5, min(rect.width, rect.height) / 2)
    let exponent: CGFloat = 5
    let corners: [(center: CGPoint, from: CGFloat)] = [
        (CGPoint(x: rect.maxX - extent, y: rect.minY + extent), -.pi / 2),
        (CGPoint(x: rect.maxX - extent, y: rect.maxY - extent), 0),
        (CGPoint(x: rect.minX + extent, y: rect.maxY - extent), .pi / 2),
        (CGPoint(x: rect.minX + extent, y: rect.minY + extent), .pi),
    ]
    let steps = 48
    for (index, corner) in corners.enumerated() {
        for step in 0...steps {
            let angle = corner.from + CGFloat(step) / CGFloat(steps) * .pi / 2
            let (cosine, sine) = (cos(angle), sin(angle))
            let point = CGPoint(x: corner.center.x + extent * copysign(pow(abs(cosine), 2 / exponent), cosine),
                                y: corner.center.y + extent * copysign(pow(abs(sine), 2 / exponent), sine))
            if index == 0 && step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
    }
    path.closeSubpath()
    return path
}

func drawBody(_ ctx: CGContext) -> CGPath {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = continuousRect(body, radius: 185)
    // Soft drop shadow, kept inside the canvas.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.45))
    ctx.addPath(path)
    ctx.setFillColor(rgb(backdrop))
    ctx.fillPath()
    ctx.restoreGState()
    // Dark frosted gradient (Låda Glass elevated → backdrop), lit from the top.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    linearGradient(ctx, [rgb(0x2E333C), rgb(elevated), rgb(backdrop)],
                   from: CGPoint(x: 0, y: body.maxY), to: CGPoint(x: 0, y: body.minY))
    // A faint accent glow in the upper-left, like light through frosted glass.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    if let glow = CGGradient(colorsSpace: space, colors: [rgb(fjord, 0.30), rgb(fjord, 0)] as CFArray, locations: nil) {
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 820), startRadius: 0,
                               endCenter: CGPoint(x: 300, y: 820), endRadius: 620, options: [])
    }
    ctx.restoreGState()
    // Thin glass rim.
    ctx.saveGState()
    ctx.addPath(continuousRect(body.insetBy(dx: 2, dy: 2), radius: 183))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()
    return path
}

func drawPhoto(_ ctx: CGContext) {
    // The photo card, slightly tilted, with a light frame.
    let card = CGRect(x: 232, y: 292, width: 560, height: 452)
    ctx.saveGState()
    ctx.translateBy(x: card.midX, y: card.midY)
    ctx.rotate(by: 4 * .pi / 180)
    ctx.translateBy(x: -card.midX, y: -card.midY)
    let frame = continuousRect(card, radius: 48)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.5))
    ctx.addPath(frame)
    ctx.setFillColor(rgb(paper))
    ctx.fillPath()
    ctx.restoreGState()

    // The picture inside the frame: sky gradient, sun, two mountains.
    let picture = card.insetBy(dx: 34, dy: 34)
    ctx.saveGState()
    ctx.addPath(continuousRect(picture, radius: 22))
    ctx.clip()
    linearGradient(ctx, [rgb(frostCyan), rgb(fjord)],
                   from: CGPoint(x: 0, y: picture.maxY), to: CGPoint(x: 0, y: picture.minY))
    ctx.setFillColor(rgb(birchGold))
    ctx.fillEllipse(in: CGRect(x: picture.minX + 300, y: picture.minY + 222, width: 112, height: 112))
    let back = CGMutablePath()
    back.move(to: CGPoint(x: picture.minX + 150, y: picture.minY - 2))
    back.addLine(to: CGPoint(x: picture.minX + 330, y: picture.minY + 210))
    back.addLine(to: CGPoint(x: picture.maxX + 40, y: picture.minY - 2))
    back.closeSubpath()
    ctx.addPath(back)
    ctx.setFillColor(rgb(0x2B5B84))
    ctx.fillPath()
    let front = CGMutablePath()
    front.move(to: CGPoint(x: picture.minX - 40, y: picture.minY - 2))
    front.addLine(to: CGPoint(x: picture.minX + 150, y: picture.minY + 270))
    front.addLine(to: CGPoint(x: picture.minX + 360, y: picture.minY - 2))
    front.closeSubpath()
    ctx.addPath(front)
    ctx.setFillColor(rgb(0x1B3A55))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.restoreGState()
}

/// One curved arrow of the convert badge: an arc of `radius` from `start` to `end` degrees
/// (counter-clockwise), with an arrowhead at the end.
func arcArrow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat) {
    let toRad = CGFloat.pi / 180
    ctx.setLineWidth(30)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: radius, startAngle: start * toRad, endAngle: end * toRad, clockwise: false)
    ctx.strokePath()
    let base = end * toRad
    let point = CGPoint(x: center.x + radius * cos(base), y: center.y + radius * sin(base))
    let normal = CGPoint(x: cos(base), y: sin(base))
    let tipAngle = base + 44 / radius
    let tip = CGPoint(x: center.x + radius * cos(tipAngle), y: center.y + radius * sin(tipAngle))
    let head = CGMutablePath()
    head.move(to: tip)
    head.addLine(to: CGPoint(x: point.x + normal.x * 42, y: point.y + normal.y * 42))
    head.addLine(to: CGPoint(x: point.x - normal.x * 42, y: point.y - normal.y * 42))
    head.closeSubpath()
    ctx.addPath(head)
    ctx.fillPath()
}

func drawBadge(_ ctx: CGContext) {
    let center = CGPoint(x: 724, y: 284)
    let radius: CGFloat = 150
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.5))
    ctx.setFillColor(rgb(fjord))
    ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    ctx.restoreGState()
    // Inner ring: a dark rim so the badge separates from the photo at small sizes.
    ctx.saveGState()
    ctx.setStrokeColor(rgb(backdrop))
    ctx.setLineWidth(16)
    ctx.strokeEllipse(in: CGRect(x: center.x - radius - 8, y: center.y - radius - 8,
                                 width: (radius + 8) * 2, height: (radius + 8) * 2))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setStrokeColor(rgb(ink))
    ctx.setFillColor(rgb(ink))
    arcArrow(ctx, center: center, radius: 82, start: 30, end: 160)
    arcArrow(ctx, center: center, radius: 82, start: 210, end: 340)
    ctx.restoreGState()
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <out.png>\n".utf8))
    exit(64)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
let body = drawBody(ctx)
ctx.saveGState()
ctx.addPath(body)
ctx.clip()
drawPhoto(ctx)
ctx.restoreGState()
drawBadge(ctx)

guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try png.write(to: URL(fileURLWithPath: arguments[1]))
} catch {
    FileHandle.standardError.write(Data("could not write \(arguments[1]): \(error)\n".utf8))
    exit(1)
}
