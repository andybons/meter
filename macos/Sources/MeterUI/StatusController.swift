import AppKit
import MeterCore

/// Owns the menu bar item and its menu; both are rendered from the model.
final class StatusController: NSObject {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let menu = NSMenu()
  private let model: UsageModel
  private let configPath: String
  private let showSettings: () -> Void

  init(model: UsageModel, configPath: String, showSettings: @escaping () -> Void) {
    self.model = model
    self.configPath = configPath
    self.showSettings = showSettings
    super.init()
    item.autosaveName = "com.andybons.Meter.status"
    item.behavior = .removalAllowed
    menu.delegate = self
    item.menu = menu
    model.onChange = { [weak self] in self?.render() }
    render()
  }

  /// Icon-only button: the gauge shows overall usage; the value is spoken.
  private func render() {
    let overview = model.overview
    guard let button = item.button else { return }
    button.image = GaugeIcon.image(fraction: overview.gaugeValue, description: "Meter")
    button.imagePosition = .imageOnly
    button.title = ""
    button.toolTip = overview.headline
    button.setAccessibilityLabel("Meter")
    button.setAccessibilityValue(overview.accessibilityValue)
  }

  private func symbol(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)
  }

  @objc private func refreshNow(_ sender: Any?) { model.refreshNow() }

  @objc private func openSettings(_ sender: Any?) { showSettings() }

  @objc private func openConfig(_ sender: Any?) {
    let url = URL(fileURLWithPath: configPath)
    if !FileManager.default.fileExists(atPath: configPath) {
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? Data(starterConfig.utf8).write(to: url)
    }
    NSWorkspace.shared.open(url)
  }

  /// Opens Terminal running the provider's login for this account.
  @objc private func logIn(_ sender: NSMenuItem) {
    guard let spec = sender.representedObject as? AccountSpec else { return }
    let name = "meter-login-\(spec.provider.title.lowercased())-\(abs(spec.dir.hashValue)).command"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    do {
      try Data(spec.loginScript.utf8).write(to: url)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    } catch {
      NSSound.beep()
      return
    }
    NSWorkspace.shared.open(
      [url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
      configuration: NSWorkspace.OpenConfiguration())
  }
}

extension StatusController: NSMenuDelegate {
  // Rebuilt before each opening so relative times ("resets in 3h") are current.
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let now = Date()

    let headline = NSMenuItem()
    headline.view = makeHeadlineView(
      model.overview.headline, updated: model.overview.updatedText(now: now))
    menu.addItem(headline)

    if let error = model.configError {
      let row = NSMenuItem()
      row.view = makeMessageRowView(
        title: "Config problem", notice: Notice(kind: .error, text: error.description))
      menu.addItem(row)
    }

    for provider in Provider.allCases {
      let rows = model.rows.filter { $0.spec.provider == provider }
      guard !rows.isEmpty else { continue }
      let header = NSMenuItem()
      header.view = makeProviderHeaderView(provider)
      menu.addItem(header)
      for r in rows {
        let d = r.display(now: now)
        let row = NSMenuItem()
        row.view = makeAccountRowView(d)
        menu.addItem(row)
        if d.needsLogin {
          let login = NSMenuItem(
            title: "Log In to \(r.spec.email)…", action: #selector(logIn(_:)), keyEquivalent: "")
          login.target = self
          login.representedObject = r.spec
          login.image = symbol("person.crop.circle.badge.plus")
          menu.addItem(login)
        }
      }
    }

    menu.addItem(.separator())
    let refresh = NSMenuItem(
      title: "Refresh Now", action: #selector(refreshNow(_:)), keyEquivalent: "r")
    refresh.target = self
    refresh.image = symbol("arrow.clockwise")
    menu.addItem(refresh)
    menu.addItem(.separator())
    let config = NSMenuItem(
      title: "Open Config File", action: #selector(openConfig(_:)), keyEquivalent: "")
    config.target = self
    config.image = symbol("doc.text")
    menu.addItem(config)
    let settings = NSMenuItem(
      title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
    settings.target = self
    settings.image = symbol("gearshape")
    menu.addItem(settings)
    menu.addItem(.separator())
    // macOS 26 gives Quit an icon by itself, which indents siblings without one.
    let quit = NSMenuItem(
      title: "Quit Meter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    quit.image = symbol("power")
    menu.addItem(quit)
  }
}

extension StatusController: NSMenuItemValidation {
  // "Refresh Now" is disabled while a refresh runs.
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(refreshNow(_:)) { return !model.isRefreshing }
    return true
  }
}
