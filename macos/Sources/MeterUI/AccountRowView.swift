import AppKit
import MeterCore

/// Width of every custom menu row.
let menuRowWidth: CGFloat = 340

private let sideInset: CGFloat = 14

/// A thin bar showing how much of a limit is used.
final class UsageBarView: NSView {
  private let fraction: Double
  private let color: NSColor

  init(fraction: Double, color: NSColor) {
    self.fraction = min(max(fraction, 0), 1)
    self.color = color
    super.init(frame: .zero)
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { nil }

  override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }

  override func draw(_ dirtyRect: NSRect) {
    let radius = bounds.height / 2
    NSColor.quaternaryLabelColor.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    guard fraction > 0 else { return }
    var fill = bounds
    fill.size.width = max(bounds.height, bounds.width * fraction)
    color.setFill()
    NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
  }
}

private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor)
  -> NSTextField
{
  let f = NSTextField(labelWithString: text)
  f.font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
  f.textColor = color
  f.lineBreakMode = .byTruncatingTail
  f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  return f
}

// Color is reserved for limits that need attention, so a red bar stands out
// among neutral ones instead of competing with a column of green.
private func barColor(for severity: Severity, active: Bool) -> NSColor {
  guard active else { return .tertiaryLabelColor }
  switch severity {
  case .normal: return .secondaryLabelColor
  case .warning: return .systemOrange
  case .critical: return .systemRed
  }
}

private func percentColor(for severity: Severity) -> NSColor {
  switch severity {
  case .normal: .labelColor
  case .warning: .systemOrange
  case .critical: .systemRed
  }
}

private func color(for kind: Notice.Kind) -> NSColor {
  switch kind {
  case .info: .secondaryLabelColor
  case .warning: .systemOrange
  case .error: .systemRed
  }
}

private func noticeLabel(_ notice: Notice) -> NSTextField {
  let f = NSTextField(wrappingLabelWithString: notice.text)
  f.font = .systemFont(ofSize: 12)
  f.textColor = color(for: notice.kind)
  f.maximumNumberOfLines = 3
  f.preferredMaxLayoutWidth = menuRowWidth - 2 * sideInset
  return f
}

/// Wraps a vertical stack into a fixed-width view whose height fits the content.
func rowContainer(_ stack: NSStackView, accessibility: String, top: CGFloat = 6) -> NSView {
  stack.orientation = .vertical
  stack.alignment = .leading
  stack.spacing = 4
  stack.edgeInsets = NSEdgeInsets(top: top, left: sideInset, bottom: 6, right: sideInset)
  stack.translatesAutoresizingMaskIntoConstraints = false
  let container = NSView(frame: NSRect(x: 0, y: 0, width: menuRowWidth, height: 10))
  container.addSubview(stack)
  NSLayoutConstraint.activate([
    stack.widthAnchor.constraint(equalToConstant: menuRowWidth),
    stack.topAnchor.constraint(equalTo: container.topAnchor),
    stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
    stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
  ])
  container.layoutSubtreeIfNeeded()
  container.frame.size = NSSize(width: menuRowWidth, height: ceil(stack.fittingSize.height))
  container.setAccessibilityElement(true)
  container.setAccessibilityRole(.group)
  container.setAccessibilityLabel(accessibility)
  return container
}

private func fullWidth(_ view: NSView, in stack: NSStackView) {
  view.widthAnchor.constraint(
    equalTo: stack.widthAnchor, constant: -(2 * sideInset)
  ).isActive = true
}

/// Fixed column widths, so percentages and reset times line up down the menu.
private enum Column {
  static let label: CGFloat = 62
  static let percent: CGFloat = 38
  static let reset: CGFloat = 50
}

private func fixedWidth(_ view: NSView, _ width: CGFloat) -> NSView {
  view.widthAnchor.constraint(equalToConstant: width).isActive = true
  view.setContentHuggingPriority(.required, for: .horizontal)
  return view
}

/// One limit on one line: label, bar, percentage, time to reset.
private func limitLine(_ l: LimitDisplay) -> NSView {
  let name = label(l.label, size: 12, color: l.isActive ? .labelColor : .secondaryLabelColor)
  let bar = UsageBarView(fraction: l.fraction, color: barColor(for: l.severity, active: l.isActive))
  let percent = label(
    l.percentText, size: 12, weight: l.severity == .critical ? .semibold : .regular,
    color: l.isActive ? percentColor(for: l.severity) : .secondaryLabelColor)
  percent.alignment = .right
  let reset = label(l.resetText, size: 11, color: .secondaryLabelColor)
  reset.alignment = .right
  bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
  let line = NSStackView(views: [
    fixedWidth(name, Column.label), bar, fixedWidth(percent, Column.percent),
    fixedWidth(reset, Column.reset),
  ])
  line.orientation = .horizontal
  line.alignment = .centerY
  line.spacing = 8
  return line
}

/// Builds the custom menu view for one account.
func makeAccountRowView(_ d: RowDisplay) -> NSView {
  let stack = NSStackView()
  // The plan sits beside the account as a badge: it describes the account, so
  // it belongs with its name rather than across the row.
  let email = label(d.title, size: 13, weight: .semibold, color: .labelColor)
  email.setContentHuggingPriority(.required, for: .horizontal)
  var views: [NSView] = [email]
  if let plan = d.plan { views.append(BadgeView(plan)) }
  let spacer = NSView()
  spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
  views.append(spacer)
  if d.isRefreshing {
    views.append(label("Refreshing…", size: 11, color: .secondaryLabelColor))
  }
  let header = NSStackView(views: views)
  header.orientation = .horizontal
  header.alignment = .centerY
  header.spacing = 6
  stack.addArrangedSubview(header)
  fullWidth(header, in: stack)
  if let notice = d.notice {
    let n = noticeLabel(notice)
    stack.addArrangedSubview(n)
    fullWidth(n, in: stack)
  }
  for l in d.limits {
    let line = limitLine(l)
    stack.addArrangedSubview(line)
    fullWidth(line, in: stack)
  }
  stack.setCustomSpacing(6, after: header)
  return rowContainer(stack, accessibility: d.accessibilityLabel)
}

/// Builds a wrapped one-notice row, used for config problems.
func makeMessageRowView(title: String, notice: Notice) -> NSView {
  let stack = NSStackView()
  stack.addArrangedSubview(label(title, size: 13, weight: .semibold, color: .labelColor))
  let n = noticeLabel(notice)
  stack.addArrangedSubview(n)
  fullWidth(n, in: stack)
  return rowContainer(stack, accessibility: "\(title). \(notice.text)")
}

/// Builds the summary at the top of the menu.
///
/// The overall figure, then when it was last updated. A custom view, since a disabled item would be dimmed.
func makeHeadlineView(_ text: String, updated: String?) -> NSView {
  let stack = NSStackView()
  stack.addArrangedSubview(label(text, size: 13, weight: .semibold, color: .labelColor))
  if let updated {
    stack.addArrangedSubview(label(updated, size: 11, color: .secondaryLabelColor))
  }
  return rowContainer(
    stack, accessibility: [text, updated].compactMap { $0 }.joined(separator: ". "))
}
