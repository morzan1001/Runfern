// Generates the Runfern app icon: a simple, bold fern frond.
//
// Usage: xcrun swiftc -O generate_icon.swift -o /tmp/generate_icon && /tmp/generate_icon <output-dir>
// Writes AppIcon.png (light), AppIcon-Dark.png, AppIcon-Tinted.png (1024 × 1024) and Fern.svg.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0

// MARK: Geometry (top-left origin, y grows downward)

func add(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
func sub(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
func mul(_ a: CGPoint, _ s: Double) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
func normalize(_ a: CGPoint) -> CGPoint { mul(a, 1 / (a.x * a.x + a.y * a.y).squareRoot()) }
func rotate(_ a: CGPoint, _ angle: Double) -> CGPoint {
    CGPoint(x: a.x * cos(angle) - a.y * sin(angle), y: a.x * sin(angle) + a.y * cos(angle))
}

// Stem: one gentle quadratic curve.
let stemStart = CGPoint(x: 0, y: 700), stemControl = CGPoint(x: -40, y: 330), stemEnd = CGPoint(x: 0, y: 0)

func stemPoint(_ t: Double) -> CGPoint {
    let u = 1 - t
    return add(add(mul(stemStart, u * u), mul(stemControl, 2 * u * t)), mul(stemEnd, t * t))
}

func stemTangent(_ t: Double) -> CGPoint {
    normalize(add(mul(sub(stemControl, stemStart), 2 * (1 - t)), mul(sub(stemEnd, stemControl), 2 * t)))
}

/// Symmetric leaf shaped like a lens, from `base` along `direction`.
func leaf(base: CGPoint, direction: CGPoint, length: Double, width: Double) -> CGPath {
    let tip = add(base, mul(direction, length))
    let middle = add(base, mul(direction, length * 0.5))
    let normal = CGPoint(x: -direction.y, y: direction.x)
    let path = CGMutablePath()
    path.move(to: base)
    path.addQuadCurve(to: tip, control: add(middle, mul(normal, width)))
    path.addQuadCurve(to: base, control: sub(middle, mul(normal, width)))
    path.closeSubpath()
    return path
}

func stemPath() -> CGPath {
    let path = CGMutablePath()
    path.move(to: stemStart)
    path.addQuadCurve(to: stemEnd, control: stemControl)
    return path.copy(strokingWithWidth: 40, lineCap: .round, lineJoin: .round, miterLimit: 1)
}

/// Five opposite pairs that shrink toward the top, plus one terminal leaf.
func leafPaths() -> [CGPath] {
    let pairs: [(t: Double, length: Double)] = [(0.14, 300), (0.30, 265), (0.46, 225), (0.61, 180), (0.75, 135)]
    var paths: [CGPath] = []
    for pair in pairs {
        let base = stemPoint(pair.t)
        let tangent = stemTangent(pair.t)
        for side in [-1.0, 1.0] {
            let direction = rotate(tangent, side * 0.9)
            paths.append(leaf(base: base, direction: direction, length: pair.length, width: pair.length * 0.27))
        }
    }
    paths.append(leaf(base: stemPoint(0.79), direction: stemTangent(1), length: 215, width: 54))
    return paths
}

/// All frond shapes, scaled and centered so the artwork fills about two thirds of the canvas.
let frondParts: [CGPath] = {
    let parts = [stemPath()] + leafPaths()
    let bounds = parts.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }
    let scale = 660 / max(bounds.width, bounds.height)
    var transform = CGAffineTransform(translationX: size / 2, y: size / 2)
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -bounds.midX, y: -bounds.midY)
    return parts.map { $0.copy(using: &transform)! }
}()

// MARK: Rendering

struct Style {
    var background: (top: CGColor, bottom: CGColor)?
    var frond: (top: CGColor, bottom: CGColor)
}

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: 1)
}

func gray(_ white: Double) -> CGColor { CGColor(gray: white, alpha: 1) }

func render(_ style: Style, to url: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Flip to the top-left coordinate system used by the geometry.
    context.translateBy(x: 0, y: size)
    context.scaleBy(x: 1, y: -1)

    func fillGradient(_ colors: (top: CGColor, bottom: CGColor)) {
        let gradient = CGGradient(colorsSpace: space, colors: [colors.top, colors.bottom] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: size / 2, y: 0), end: CGPoint(x: size / 2, y: size), options: [])
    }

    if let background = style.background { fillGradient(background) }
    // Fill each shape separately so overlaps never cancel out, then tint the union with the gradient.
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.setFillColor(gray(1))
    frondParts.forEach { context.addPath($0); context.fillPath() }
    context.setBlendMode(.sourceIn)
    fillGradient(style.frond)
    context.endTransparencyLayer()

    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

/// Vector version of the frond for Icon Composer (no background; the system supplies effects).
func svg() -> String {
    let paths = frondParts.map { part -> String in
        var d = ""
        part.applyWithBlock { element in
            let p = element.pointee.points
            func f(_ point: CGPoint) -> String { String(format: "%.1f %.1f", point.x, point.y) }
            switch element.pointee.type {
            case .moveToPoint: d += "M\(f(p[0]))"
            case .addLineToPoint: d += "L\(f(p[0]))"
            case .addQuadCurveToPoint: d += "Q\(f(p[0])) \(f(p[1]))"
            case .addCurveToPoint: d += "C\(f(p[0])) \(f(p[1])) \(f(p[2]))"
            case .closeSubpath: d += "Z"
            @unknown default: break
            }
        }
        return "  <path d=\"\(d)\"/>"
    }
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
    <g fill="#F2FAE6">
    \(paths.joined(separator: "\n"))
    </g>
    </svg>

    """
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".", isDirectory: true)
try render(Style(background: (color(0x2E9E66), color(0x0C4532)), frond: (color(0xF4FBE9), color(0xC6EBA8))),
           to: output.appendingPathComponent("AppIcon.png"))
try render(Style(background: nil, frond: (color(0x9BE3AE), color(0x3FAE6C))),
           to: output.appendingPathComponent("AppIcon-Dark.png"))
try render(Style(background: nil, frond: (gray(1.0), gray(0.78))),
           to: output.appendingPathComponent("AppIcon-Tinted.png"))
try svg().write(to: output.appendingPathComponent("Fern.svg"), atomically: true, encoding: .utf8)
print("Wrote icons to \(output.path)")
