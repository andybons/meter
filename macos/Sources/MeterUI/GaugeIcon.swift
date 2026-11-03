import AppKit

/// The menu bar icon: a gauge arc that fills with overall usage.
nonisolated enum GaugeIcon {
  /// A template image whose arc is `fraction` (0...1) full.
  static func image(fraction: Double, description: String) -> NSImage {
    let f = min(max(fraction, 0), 1)
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      let center = NSPoint(x: 9, y: 8)
      let start: CGFloat = 210
      let sweep: CGFloat = 240
      func arc(_ degrees: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.appendArc(
          withCenter: center, radius: 6.5, startAngle: start, endAngle: start - degrees,
          clockwise: true)
        p.lineWidth = 2.6
        p.lineCapStyle = .round
        return p
      }
      NSColor.black.withAlphaComponent(0.35).setStroke()
      arc(sweep).stroke()
      if f > 0 {
        NSColor.black.setStroke()
        arc(sweep * CGFloat(f)).stroke()
      }
      NSColor.black.setFill()
      NSBezierPath(ovalIn: NSRect(x: center.x - 1.4, y: center.y - 1.4, width: 2.8, height: 2.8))
        .fill()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = description
    return image
  }
}
