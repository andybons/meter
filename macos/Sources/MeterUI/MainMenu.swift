import AppKit

/// Builds the main menu.
///
/// An accessory app never shows it, but it routes ⌘W, ⌘Q and ⌘, to the
/// Settings window.
func makeMainMenu(settings: Selector) -> NSMenu {
  let main = NSMenu()
  func submenu(_ title: String, _ build: (NSMenu) -> Void) {
    let menu = NSMenu(title: title)
    build(menu)
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = menu
    main.addItem(item)
  }
  submenu("Meter") { m in
    m.addItem(withTitle: "Settings…", action: settings, keyEquivalent: ",")
    m.addItem(.separator())
    m.addItem(
      withTitle: "Hide Meter", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    m.addItem(.separator())
    m.addItem(
      withTitle: "Quit Meter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
  }
  submenu("Window") { m in
    m.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    m.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"
    )
    NSApp.windowsMenu = m
  }
  return main
}
