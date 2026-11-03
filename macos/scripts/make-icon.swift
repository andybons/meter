// Draws Meter's app icon and writes an .iconset for iconutil.
//
//   swift scripts/make-icon.swift <out.iconset>
//
// The icon is drawn in code so it can be regenerated and reviewed in diffs.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

/// Mixes two colors; `t` is 0...1.
func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
  a.blended(withFraction: t, of: b) ?? a
}

let green = NSColor(srgbRed: 0.30, green: 0.84, blue: 0.45, alpha: 1)
let yellow = NSColor(srgbRed: 1.00, green: 0.80, blue: 0.20, alpha: 1)
let red = NSColor(srgbRed: 1.00, green: 0.33, blue: 0.30, alpha: 1)

/// The meter's color at `t` along the arc: green, then yellow, then red.
func meterColor(_ t: CGFloat) -> NSColor {
  t < 0.5 ? mix(green, yellow, t * 2) : mix(yellow, red, (t - 0.5) * 2)
}

/// Draws the icon into a 1024-point square.
func drawIcon() {
  // macOS app icon grid: an 824-point rounded square, inset 100 points.
  let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
  let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
  shadow.shadowBlurRadius = 24
  shadow.shadowOffset = NSSize(width: 0, height: -10)
  shadow.set()
  NSColor.black.setFill()
  shape.fill()
  NSGraphicsContext.restoreGraphicsState()

  NSGradient(
    starting: NSColor(srgbRed: 0.20, green: 0.22, blue: 0.26, alpha: 1),
    ending: NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 1)
  )?.draw(in: shape, angle: -90)
  NSColor.white.withAlphaComponent(0.10).setStroke()
  shape.lineWidth = 3
  shape.stroke()

  let center = NSPoint(x: 512, y: 470)
  let radius: CGFloat = 255
  let start: CGFloat = 210
  let sweep: CGFloat = 240
  let fill: CGFloat = 0.68

  func arc(from a: CGFloat, to b: CGFloat, width: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.appendArc(withCenter: center, radius: radius, startAngle: a, endAngle: b, clockwise: true)
    p.lineWidth = width
    p.lineCapStyle = .round
    return p
  }

  NSColor.white.withAlphaComponent(0.12).setStroke()
  arc(from: start, to: start - sweep, width: 68).stroke()

  // The filled part, drawn as short overlapping segments so its color runs
  // from green to red along the arc.
  let steps = 120
  for i in 0..<steps {
    let t0 = CGFloat(i) / CGFloat(steps) * fill
    let t1 = min(fill, CGFloat(i + 1) / CGFloat(steps) * fill + 0.004)
    meterColor(t0 / 1).setStroke()
    let seg = arc(from: start - sweep * t0, to: start - sweep * t1, width: 68)
    seg.lineCapStyle = i == 0 || i == steps - 1 ? .round : .butt
    seg.stroke()
  }

  // Needle and hub.
  let angle = (start - sweep * fill) * .pi / 180
  let tip = NSPoint(x: center.x + cos(angle) * 185, y: center.y + sin(angle) * 185)
  let needle = NSBezierPath()
  needle.move(to: center)
  needle.line(to: tip)
  needle.lineWidth = 26
  needle.lineCapStyle = .round
  NSColor.white.setStroke()
  needle.stroke()
  NSColor.white.setFill()
  NSBezierPath(ovalIn: NSRect(x: center.x - 46, y: center.y - 46, width: 92, height: 92)).fill()
  NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1).setFill()
  NSBezierPath(ovalIn: NSRect(x: center.x - 18, y: center.y - 18, width: 36, height: 36)).fill()
}

/// Renders the icon at `pixels` square and writes it as a PNG.
func write(pixels: Int, to path: String) throws {
  guard
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: rep)
  else { throw CocoaError(.fileWriteUnknown) }
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  context.imageInterpolation = .high
  let scale = CGFloat(pixels) / 1024
  let transform = NSAffineTransform()
  transform.scale(by: scale)
  transform.concat()
  drawIcon()
  NSGraphicsContext.restoreGraphicsState()
  guard let png = rep.representation(using: .png, properties: [:]) else {
    throw CocoaError(.fileWriteUnknown)
  }
  try png.write(to: URL(fileURLWithPath: path))
}

for size in [16, 32, 128, 256, 512] {
  try write(pixels: size, to: "\(out)/icon_\(size)x\(size).png")
  try write(pixels: size * 2, to: "\(out)/icon_\(size)x\(size)@2x.png")
}
