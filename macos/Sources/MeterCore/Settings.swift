public import Foundation

/// An auto-refresh interval the Settings popup offers.
public struct RefreshInterval: Sendable, Equatable, Hashable {
  /// Length in seconds.
  public let seconds: TimeInterval
  /// Menu title.
  public let title: String

  /// 30 seconds through 10 minutes.
  public static let presets = [
    RefreshInterval(seconds: 30, title: "30 seconds"),
    RefreshInterval(seconds: 60, title: "1 minute"),
    RefreshInterval(seconds: 120, title: "2 minutes"),
    RefreshInterval(seconds: 300, title: "5 minutes"),
    RefreshInterval(seconds: 600, title: "10 minutes"),
  ]

  /// The default, 2 minutes.
  public static let standard = presets[2]

  /// The closest preset at or above `seconds`, or the longest.
  public static func closest(atLeast seconds: TimeInterval) -> RefreshInterval {
    presets.first { $0.seconds >= seconds } ?? presets[presets.count - 1]
  }

  /// The interval to use: the user's choice, else the config's, else 2 minutes.
  public static func resolve(stored: TimeInterval?, config: TimeInterval?) -> RefreshInterval {
    if let stored, let hit = presets.first(where: { $0.seconds == stored }) { return hit }
    if let config, config > 0 { return closest(atLeast: config) }
    return standard
  }
}

/// The app's own persisted settings.
public protocol SettingsStore: Sendable {
  /// The interval the user picked, if any.
  var refreshSeconds: TimeInterval? { get }
  /// Saves the user's pick.
  func setRefreshSeconds(_ seconds: TimeInterval)
}

/// Settings in the app's UserDefaults.
public struct DefaultsSettings: SettingsStore {
  private static let key = "refreshSeconds"

  /// Creates the store.
  public init() {}

  /// The saved interval, if any.
  public var refreshSeconds: TimeInterval? {
    let v = UserDefaults.standard.double(forKey: Self.key)
    return v > 0 ? v : nil
  }

  /// Saves the interval.
  public func setRefreshSeconds(_ seconds: TimeInterval) {
    UserDefaults.standard.set(seconds, forKey: Self.key)
  }
}

/// What "Open Config File" writes when there is no config yet.
public let starterConfig = """
  # Meter accounts. Omit dir to use the default ~/.claude or ~/.codex.
  # refresh = "2m"

  # [[claude]]
  # email = "you@example.com"

  # [[claude]]
  # email = "you@work.example"
  # dir = "~/.claude-you@work.example"

  # [[codex]]
  # email = "you@example.com"

  """
