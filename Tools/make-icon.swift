#!/usr/bin/env swift
// Draws Reopen's icon: a stack of windows coming back to the front, with a reopen badge.
// Used by Tools/make-icon.sh, which assembles the .icns.
//
//   swift Tools/make-icon.swift <iconset directory> [preview.png]
import AppKit

let arguments = CommandLine.arguments
let outputDirectory = arguments.count > 1 ? arguments[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

/// Everything is laid out on a 1024-unit canvas, then scaled to each pixel size.
let canvas: CGFloat = 1024
/// macOS icon grid: an 824-unit body centred on the canvas, leaving room for its shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let contentScale = body.width / canvas
/// Shadows are measured in device pixels, not canvas units, so they're scaled by hand.
var pixelScale: CGFloat = 1

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func setShadow(alpha: CGFloat, blur: CGFloat, offsetY: CGFloat, scale: CGFloat) {
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.shadowBlurRadius = blur * scale
    shadow.shadowOffset = NSSize(width: 0, height: offsetY * scale)
    shadow.set()
}

func window(_ rect: NSRect, fill: NSColor, frontmost: Bool) {
    NSGraphicsContext.saveGraphicsState()
    if frontmost { setShadow(alpha: 0.35, blur: 41, offsetY: -15, scale: pixelScale * contentScale) }
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 56, yRadius: 56).fill()
    NSGraphicsContext.restoreGraphicsState()
    guard frontmost else { return }

    // Traffic lights.
    let radius = rect.width * 0.045
    for (index, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
        let center = NSPoint(x: rect.minX + rect.width * 0.1 + CGFloat(index) * radius * 2.8, y: rect.maxY - rect.width * 0.1)
        color(hex).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
    }
    // Two lines of content.
    color(0xD9DCE3).setFill()
    for (index, widthFactor) in [CGFloat(0.62), 0.42].enumerated() {
        let bar = NSRect(x: rect.minX + rect.width * 0.1, y: rect.maxY - rect.height * (0.42 + CGFloat(index) * 0.2),
                         width: rect.width * widthFactor, height: rect.height * 0.08)
        NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
    }
}

/// Counterclockwise arc from `start`° to `end`°, ending in an arrowhead that follows the arc's tangent.
func reopenArrow(center: NSPoint, radius: CGFloat, start: CGFloat, end: CGFloat, width: CGFloat, fill: NSColor) {
    let headLength = width * 1.5
    let baseAngle = (end - (headLength * 0.8 / radius) * 180 / .pi) * .pi / 180
    let base = NSPoint(x: center.x + radius * cos(baseAngle), y: center.y + radius * sin(baseAngle))
    let direction = NSPoint(x: -sin(baseAngle), y: cos(baseAngle))
    let normal = NSPoint(x: -direction.y, y: direction.x)

    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: baseAngle * 180 / .pi, clockwise: false)
    arc.lineWidth = width
    arc.lineCapStyle = .round
    fill.setStroke()
    arc.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: base.x + direction.x * headLength, y: base.y + direction.y * headLength))
    head.line(to: NSPoint(x: base.x + normal.x * width * 1.1, y: base.y + normal.y * width * 1.1))
    head.line(to: NSPoint(x: base.x - normal.x * width * 1.1, y: base.y - normal.y * width * 1.1))
    head.close()
    head.lineJoinStyle = .round
    head.lineWidth = width * 0.25
    fill.setFill()
    head.fill()
    head.stroke()
}

func drawIcon() {
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)
    NSGraphicsContext.saveGraphicsState()
    setShadow(alpha: 0.3, blur: 20, offsetY: -8, scale: pixelScale)
    color(0xE33D6E).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0xFF9A4D), color(0xE33D6E)])?.draw(in: squircle, angle: -90)

    // The artwork is drawn full-canvas, then fitted into the body.
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: body.minX, yBy: body.minY)
    transform.scale(by: contentScale)
    transform.concat()

    window(NSRect(x: 307, y: 369, width: 512, height: 389), fill: NSColor.white.withAlphaComponent(0.3), frontmost: false)
    window(NSRect(x: 256, y: 297, width: 512, height: 389), fill: NSColor.white.withAlphaComponent(0.55), frontmost: false)
    window(NSRect(x: 205, y: 225, width: 512, height: 389), fill: .white, frontmost: true)

    let badge = NSRect(x: 573, y: 143, width: 307, height: 307)
    NSGraphicsContext.saveGraphicsState()
    setShadow(alpha: 0.3, blur: 31, offsetY: 0, scale: pixelScale * contentScale)
    color(0x1F1B3A).setFill()
    NSBezierPath(ovalIn: badge).fill()
    NSGraphicsContext.restoreGraphicsState()
    reopenArrow(center: NSPoint(x: badge.midX, y: badge.midY), radius: 87, start: -40, end: 220, width: 36, fill: .white)

    NSGraphicsContext.restoreGraphicsState()
}

func writePNG(pixels: Int, to path: String) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    pixelScale = CGFloat(pixels) / canvas
    context.cgContext.scaleBy(x: pixelScale, y: pixelScale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

for size in [16, 32, 128, 256, 512] {
    writePNG(pixels: size, to: "\(outputDirectory)/icon_\(size)x\(size).png")
    writePNG(pixels: size * 2, to: "\(outputDirectory)/icon_\(size)x\(size)@2x.png")
}
if arguments.count > 2 {
    writePNG(pixels: 512, to: arguments[2])
}
print("Icon written to \(outputDirectory)")
