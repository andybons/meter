public import AppKit
public import MeterCore

/// Owns the model, the menu bar item and the Settings window.
public final class AppDelegate: NSObject, NSApplicationDelegate {
  private let model: UsageModel
  private let configPath: String
  private var status: StatusController?
  private lazy var settings = SettingsWindowController(
    current: { [model] in model.interval },
    onChange: { [model] in model.setInterval($0) })

  /// Creates the delegate. `makeFetcher` builds the rate-limited fetcher for an account.
  public init(
    loader: ConfigLoader, makeFetcher: @escaping (AccountSpec) -> AccountFetcher,
    settings: any SettingsStore
  ) {
    self.configPath = loader.path
    self.model = UsageModel(loader: loader, makeFetcher: makeFetcher, settings: settings)
  }

  /// Installs the menu bar item and starts refreshing.
  public func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    NSApp.mainMenu = makeMainMenu(settings: #selector(showSettings(_:)))
    status = StatusController(
      model: model, configPath: configPath, showSettings: { [weak self] in self?.settings.show() })
    model.start()
  }

  /// A menu bar app keeps running with no windows.
  public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// Opts into secure state restoration.
  public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  /// Shows the Settings window.
  @objc public func showSettings(_ sender: Any?) { settings.show() }
}
