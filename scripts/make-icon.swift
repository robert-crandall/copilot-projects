import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Renders the copilot-projects app icon to a 1024x1024 PNG.
// Usage: swift make-icon.swift <out.png>

let S = 1024.0
let cs = CGColorSpaceCreateDeviceRGB()

func col(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r / 255, g / 255, b / 255, a])!
}
func rrect(_ rect: CGRect, _ radius: Double) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

guard let ctx = CGContext(
    data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

// --- squircle background with a vibrant diagonal gradient ---
let margin = 70.0
let bg = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let bgRadius = 208.0
ctx.saveGState()
ctx.addPath(rrect(bg, bgRadius))
ctx.clip()
let grad = CGGradient(colorsSpace: cs,
                      colors: [col(99, 102, 241), col(124, 58, 237)] as CFArray, // indigo -> violet
                      locations: [0, 1])!
ctx.drawLinearGradient(grad,
                       start: CGPoint(x: bg.minX, y: bg.maxY),
                       end: CGPoint(x: bg.maxX, y: bg.minY), options: [])
// soft top sheen
let sheen = CGGradient(colorsSpace: cs,
                       colors: [col(255, 255, 255, 0.16), col(255, 255, 255, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen,
                       start: CGPoint(x: bg.midX, y: bg.maxY),
                       end: CGPoint(x: bg.midX, y: bg.midY + 60), options: [])
ctx.restoreGState()

// --- dark terminal "screen" inset ---
let screen = bg.insetBy(dx: 88, dy: 88)
let screenRadius = 130.0
ctx.saveGState()
ctx.addPath(rrect(screen, screenRadius))
ctx.clip()
let screenGrad = CGGradient(colorsSpace: cs,
                            colors: [col(23, 28, 56), col(11, 14, 32)] as CFArray,
                            locations: [0, 1])!
ctx.drawLinearGradient(screenGrad,
                       start: CGPoint(x: screen.midX, y: screen.maxY),
                       end: CGPoint(x: screen.midX, y: screen.minY), options: [])
ctx.restoreGState()
// rim light on the screen
ctx.addPath(rrect(screen.insetBy(dx: 1.5, dy: 1.5), screenRadius - 1.5))
ctx.setStrokeColor(col(255, 255, 255, 0.07))
ctx.setLineWidth(3)
ctx.strokePath()

// --- session "tab" pills along the top of the screen ---
let pillH = 40.0
let pillW = 150.0
let pillGap = 30.0
let pillY = screen.maxY - 96 - pillH
let pillX0 = screen.minX + 78
let pillFills = [col(96, 132, 250), col(60, 70, 104), col(60, 70, 104)]
for i in 0..<3 {
    let r = CGRect(x: pillX0 + Double(i) * (pillW + pillGap), y: pillY, width: pillW, height: pillH)
    ctx.addPath(rrect(r, pillH / 2))
    ctx.setFillColor(pillFills[i])
    ctx.fillPath()
}

// --- prompt chevron ">" ---
let midY = screen.midY - 12
ctx.saveGState()
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setStrokeColor(col(238, 242, 255))
ctx.setLineWidth(72)
let chX = screen.minX + 168
let chPointX = chX + 196
ctx.move(to: CGPoint(x: chX, y: midY + 160))
ctx.addLine(to: CGPoint(x: chPointX, y: midY))
ctx.addLine(to: CGPoint(x: chX, y: midY - 160))
ctx.strokePath()
ctx.restoreGState()

// --- amber cursor block with glow ---
let cursor = CGRect(x: chPointX + 96, y: midY - 160, width: 80, height: 248)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 46, color: col(255, 176, 32, 0.95))
ctx.addPath(rrect(cursor, 22))
ctx.setFillColor(col(255, 184, 56))
ctx.fillPath()
ctx.restoreGState()

guard let image = ctx.makeImage() else { exit(1) }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let url = URL(fileURLWithPath: out)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
