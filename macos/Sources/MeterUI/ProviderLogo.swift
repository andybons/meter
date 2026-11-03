import AppKit
import MeterCore

/// The provider's logo, from its installed Mac app.
///
/// Using the app's icon means no brand artwork is copied into this
/// repository. Falls back to an SF Symbol when the app isn't installed.
enum ProviderLogo {
  private static var cache: [Provider: NSImage] = [:]

  static func image(for provider: Provider) -> NSImage {
    if let cached = cache[provider] { return cached }
    let image: NSImage
    if let url = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: provider.appBundleIdentifier)
    {
      image = NSWorkspace.shared.icon(forFile: url.path)
    } else {
      let name = provider == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right"
      image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }
    image.size = NSSize(width: 16, height: 16)
    cache[provider] = image
    return image
  }
}

/// A small rounded badge, such as a plan name next to an account.
final class BadgeView: NSView {
  private let text: NSAttributedString
  private static let padding = NSSize(width: 6, height: 1)

  init(_ string: String) {
    text = NSAttributedString(
      string: string,
      attributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor,
      ])
    super.init(frame: .zero)
    setAccessibilityElement(false)
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not used") }

  override var intrinsicContentSize: NSSize {
    let size = text.size()
    return NSSize(
      width: ceil(size.width) + 2 * Self.padding.width,
      height: ceil(size.height) + 2 * Self.padding.height)
  }

  // Drawn in draw(_:), where semantic colors resolve for the current appearance.
  override func draw(_ dirtyRect: NSRect) {
    let radius = bounds.height / 2
    NSColor.quaternaryLabelColor.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    let size = text.size()
    text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
  }
}

/// A section header with the provider's logo.
func makeProviderHeaderView(_ provider: Provider) -> NSView {
  let icon = NSImageView(image: ProviderLogo.image(for: provider))
  icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
  icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
  let title = NSTextField(labelWithString: provider.title)
  title.font = .systemFont(ofSize: 12, weight: .semibold)
  title.textColor = .secondaryLabelColor
  let row = NSStackView(views: [icon, title])
  row.orientation = .horizontal
  row.spacing = 6
  row.alignment = .centerY
  let stack = NSStackView(views: [row])
  return rowContainer(stack, accessibility: provider.title, top: 8)
}
