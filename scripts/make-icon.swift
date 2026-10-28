// Draws the app icon (1024 × 1024): rounded square macOS style, blue → purple gradient, "play" triangle.
// Usage : swift scripts/make-icon.swift <sortie.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
// Bitmap context at the exact size (no Retina scaling) and transparent background.
guard let context = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

// Standard margin of macOS icons (the rounded square takes ~80% of the frame).
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
context.addPath(shape)
context.setFillColor(NSColor.black.cgColor)
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(shape)
context.clip()
let colors = [
    NSColor(red: 0.0, green: 0.643, blue: 0.863, alpha: 1).cgColor,
    NSColor(red: 0.667, green: 0.361, blue: 0.765, alpha: 1).cgColor
] as CFArray
if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
}
// Soft highlight at the top
context.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
context.fillEllipse(in: CGRect(x: rect.minX - 200, y: rect.midY + 60, width: rect.width + 400, height: rect.height))
context.restoreGState()

// "Play" triangle with rounded corners, slightly shifted to the right (optical centre).
let triangle = CGMutablePath()
let cx = size / 2 + 30, cy = size / 2, h: CGFloat = 330
triangle.move(to: CGPoint(x: cx - h * 0.45, y: cy + h / 2))
triangle.addLine(to: CGPoint(x: cx + h * 0.55, y: cy))
triangle.addLine(to: CGPoint(x: cx - h * 0.45, y: cy - h / 2))
triangle.closeSubpath()
// A single shadow for the whole shape (transparency layer), no inner shadow.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor.black.withAlphaComponent(0.25).cgColor)
context.beginTransparencyLayer(auxiliaryInfo: nil)
context.addPath(triangle)
context.setFillColor(NSColor.white.cgColor)
context.fillPath()
context.addPath(triangle)
context.setLineJoin(.round)
context.setLineWidth(70)
context.setStrokeColor(NSColor.white.cgColor)
context.strokePath()
context.endTransparencyLayer()
context.restoreGState()

guard let cgImage = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: output))
print("Icon written: \(output)")
