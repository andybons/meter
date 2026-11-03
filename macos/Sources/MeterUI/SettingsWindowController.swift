import AppKit
import MeterCore

/// The single Settings window: the auto-refresh interval.
final class SettingsWindowController: NSWindowController {
  private let onChange: (RefreshInterval) -> Void
  private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

  init(current: @escaping () -> RefreshInterval, onChange: @escaping (RefreshInterval) -> Void) {
    self.onChange = onChange
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true
    )
    window.title = "Meter Settings"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    windowFrameAutosaveName = "settings"

    let label = NSTextField(labelWithString: "Refresh every:")
    for preset in RefreshInterval.presets { popup.addItem(withTitle: preset.title) }
    popup.target = self
    popup.action = #selector(changed(_:))
    popup.setAccessibilityLabel("Refresh interval")
    label.setAccessibilityElement(false)
    let row = NSStackView(views: [label, popup])
    row.spacing = 8
    let note = NSTextField(
      wrappingLabelWithString:
        "Claude accounts are asked at most every 2 minutes, since the usage endpoint only allows a few calls per token."
    )
    note.font = .systemFont(ofSize: 11)
    note.textColor = .secondaryLabelColor
    note.preferredMaxLayoutWidth = 340
    let stack = NSStackView(views: [row, note])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    window.contentView = stack
    window.setContentSize(stack.fittingSize)
    self.current = current
  }

  private var current: (() -> RefreshInterval)?

  required init?(coder: NSCoder) { nil }

  @objc private func changed(_ sender: NSPopUpButton) {
    let i = sender.indexOfSelectedItem
    guard RefreshInterval.presets.indices.contains(i) else { return }
    onChange(RefreshInterval.presets[i])
  }

  /// Shows the window, activating first since accessory apps are not active when their menu
  /// bar item is clicked.
  func show() {
    if let c = current?(), let i = RefreshInterval.presets.firstIndex(of: c) {
      popup.selectItem(at: i)
    }
    if window?.isVisible == false, window?.setFrameUsingName("settings") == false {
      window?.center()
    }
    NSApp.activate()
    showWindow(nil)
  }
}
