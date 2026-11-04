import AppKit
import MeterCore

/// Owns the menu bar item and its menu; both are rendered from the model.
final class StatusController: NSObject {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let menu = NSMenu()
  private let model: UsageModel
  private let configPath: String
  private let showSettings: () -> Void
  // While the menu is open: the rows that show times, and the timer that
  // re-renders them so countdowns and "updated" text stay live.
  private var headlineItem: NSMenuItem?
  private var accountItems: [(item: NSMenuItem, spec: AccountSpec)] = []
  private var ticker: Timer?

  init(model: UsageModel, configPath: String, showSettings: @escaping () -> Void) {
    self.model = model
    self.configPath = configPath
    self.showSettings = showSettings
    super.init()
    item.autosaveName = "com.andybons.Meter.status"
    item.behavior = .removalAllowed
    menu.delegate = self
    item.menu = menu
    model.onChange = { [weak self] in
      self?.render()
      self?.updateOpenMenu()
    }
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

  /// Re-renders the open menu's live rows in place; its structure is left alone.
  private func updateOpenMenu() {
    guard ticker != nil else { return }
    let now = Date()
    headlineItem?.view = makeHeadlineView(
      model.overview.headline, updated: model.overview.updatedText(now: now))
    for (item, spec) in accountItems {
      guard let r = model.rows.first(where: { $0.spec == spec }) else { continue }
      item.view = makeAccountRowView(r.display(now: now))
    }
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
    accountItems = []
    let now = Date()

    let headline = NSMenuItem()
    headlineItem = headline
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
        accountItems.append((row, r.spec))
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

extension StatusController {
  // A menu tracks events in its own run loop mode, so the timer runs in
  // .common to keep firing while it's open.
  func menuWillOpen(_ menu: NSMenu) {
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateOpenMenu() }
    }
    RunLoop.main.add(timer, forMode: .common)
    ticker = timer
  }

  func menuDidClose(_ menu: NSMenu) {
    ticker?.invalidate()
    ticker = nil
    headlineItem = nil
    accountItems = []
  }
}

extension StatusController: NSMenuItemValidation {
  // "Refresh Now" is disabled while a refresh runs.
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(refreshNow(_:)) { return !model.isRefreshing }
    return true
  }
}
