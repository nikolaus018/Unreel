// Renders the app icon (1024x1024 PNG). Usage: swift Scripts/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Background: deep plum to crimson to warm orange.
let colors = [NSColor(srgbRed: 0.20, green: 0.04, blue: 0.16, alpha: 1).cgColor,
              NSColor(srgbRed: 0.86, green: 0.08, blue: 0.24, alpha: 1).cgColor,
              NSColor(srgbRed: 1.00, green: 0.47, blue: 0.20, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Soft glow behind the mark.
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor(white: 1, alpha: 0.22).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size/2, y: size/2), startRadius: 0, endCenter: CGPoint(x: size/2, y: size/2), endRadius: size*0.5, options: [])

let c = CGPoint(x: size/2, y: size/2)
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor(white: 0, alpha: 0.35).cgColor)

// Reel ring with an open gap (the "un-reel").
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineWidth(58)
ctx.setLineCap(.round)
ctx.addArc(center: c, radius: 300, startAngle: .pi * 0.30, endAngle: .pi * 2.05, clockwise: false)
ctx.strokePath()

// Rounded play triangle.
let tri = CGMutablePath()
let r: CGFloat = 170
let p1 = CGPoint(x: c.x - r*0.62, y: c.y + r)
let p2 = CGPoint(x: c.x - r*0.62, y: c.y - r)
let p3 = CGPoint(x: c.x + r*1.05, y: c.y)
tri.move(to: CGPoint(x: (p1.x+p2.x)/2, y: (p1.y+p2.y)/2))
tri.addArc(tangent1End: p2, tangent2End: p3, radius: 40)
tri.addArc(tangent1End: p3, tangent2End: p1, radius: 40)
tri.addArc(tangent1End: p1, tangent2End: p2, radius: 40)
tri.closeSubpath()
ctx.addPath(tri)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
