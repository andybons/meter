import AppKit
import MeterCore

/// The single Settings window: opening at login and the auto-refresh interval.
final class SettingsWindowController: NSWindowController {
  private let onChange: (RefreshInterval) -> Void
  private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let loginItem: any LoginItemService
  private let loginCheckbox = NSButton(checkboxWithTitle: "Open at Login", target: nil, action: nil)
  private let loginNote = NSTextField(wrappingLabelWithString: "")
  private let approveButton = NSButton(
    title: "Open Login Items Settings…", target: nil, action: nil)

  init(
    current: @escaping () -> RefreshInterval, onChange: @escaping (RefreshInterval) -> Void,
    loginItem: any LoginItemService
  ) {
    self.onChange = onChange
    self.loginItem = loginItem
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
    note.preferredMaxLayoutWidth = 300
    loginCheckbox.target = self
    loginCheckbox.action = #selector(toggleLogin(_:))
    loginNote.font = .systemFont(ofSize: 11)
    loginNote.textColor = .secondaryLabelColor
    loginNote.preferredMaxLayoutWidth = 300
    approveButton.target = self
    approveButton.action = #selector(openLoginItems(_:))
    approveButton.controlSize = .small
    let login = NSStackView(views: [loginCheckbox, loginNote, approveButton])
    login.orientation = .vertical
    login.alignment = .leading
    login.spacing = 6
    let stack = NSStackView(views: [login, row, note])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.setCustomSpacing(20, after: login)
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    // A fixed width keeps the 20-point margins: notes wrap at 300 points.
    stack.widthAnchor.constraint(equalToConstant: 340).isActive = true
    window.contentView = stack
    window.setContentSize(stack.fittingSize)
    self.current = current
  }

  private var current: (() -> RefreshInterval)?

  required init?(coder: NSCoder) { nil }

  /// Shows the system's current login-item status.
  ///
  /// The status is read fresh each time, since the user can change it in
  /// System Settings while this window is closed.
  private func renderLoginItem() {
    let d = LoginItemDisplay(status: loginItem.status, appPath: Bundle.main.bundlePath)
    loginCheckbox.state = d.isOn ? .on : .off
    loginCheckbox.isEnabled = d.isEnabled
    loginNote.stringValue = d.note ?? ""
    loginNote.isHidden = d.note == nil
    approveButton.isHidden = !d.offersSystemSettings
    window?.setContentSize(window?.contentView?.fittingSize ?? .zero)
  }

  @objc private func toggleLogin(_ sender: NSButton) {
    do {
      try loginItem.setEnabled(sender.state == .on)
    } catch {
      if let window { NSAlert(error: error).beginSheetModal(for: window) }
    }
    renderLoginItem()
  }

  @objc private func openLoginItems(_ sender: Any?) {
    SystemLoginItem.openSystemSettings()
  }

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
    renderLoginItem()
    NSApp.activate()
    showWindow(nil)
  }
}
