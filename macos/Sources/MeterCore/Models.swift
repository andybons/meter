public import Foundation

/// Which service an account belongs to.
public enum Provider: Sendable, Equatable, Hashable, CaseIterable {
  case claude
  case codex

  /// Display name, as in the config errors and menu section headers.
  public var title: String {
    switch self {
    case .claude: "Claude"
    case .codex: "Codex"
    }
  }

  /// The bundle identifier of the provider's Mac app, whose icon is used as
  /// the provider's logo when it's installed.
  public var appBundleIdentifier: String {
    switch self {
    case .claude: "com.anthropic.claudefordesktop"
    case .codex: "com.openai.codex"
    }
  }
}

/// One login, isolated by its own config directory.
public struct AccountSpec: Sendable, Equatable, Hashable {
  /// The service.
  public var provider: Provider
  /// The label shown in the menu.
  public var email: String
  /// Absolute, clean CLAUDE_CONFIG_DIR / CODEX_HOME; empty means the provider's stock dir.
  public var dir: String

  /// Creates an account.
  public init(provider: Provider, email: String, dir: String = "") {
    self.provider = provider
    self.email = email
    self.dir = dir
  }

  /// Where the account's files live, default or not.
  public func dataDir(home: String) -> String {
    if !dir.isEmpty { return dir }
    return home + (provider == .codex ? "/.codex" : "/.claude")
  }

  /// The environment variable that selects a non-default dir.
  public var envVar: String { provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR" }

  /// The shortest time between real requests for this account.
  ///
  /// The Claude usage endpoint
  /// allows only about five calls per token every five minutes, so each account has to be
  /// asked less often rather than spaced out.
  public var minFetchGap: TimeInterval { provider == .claude ? 120 : 30 }
}

/// One rate-limit window.
public struct Limit: Sendable, Equatable {
  /// Window name such as "Session" or "Weekly".
  public var label: String
  /// Used share of the window, 0 to 100.
  public var percent: Double
  /// When the window resets, if known.
  public var resetsAt: Date?
  /// False for limits that do not currently apply.
  public var isActive: Bool

  /// Creates a limit.
  public init(label: String, percent: Double, resetsAt: Date?, isActive: Bool) {
    self.label = label
    self.percent = percent
    self.resetsAt = resetsAt
    self.isActive = isActive
  }
}

/// An account's plan and limits at one moment.
public struct Usage: Sendable, Equatable {
  /// Plan name such as "max 20x".
  public var plan: String
  /// Every window the provider reported.
  public var limits: [Limit]
  /// When this was fetched.
  public var fetchedAt: Date

  /// Creates a usage value.
  public init(plan: String, limits: [Limit], fetchedAt: Date = Date(timeIntervalSince1970: 0)) {
    self.plan = plan
    self.limits = limits
    self.fetchedAt = fetchedAt
  }
}

/// Why a fetch did not produce fresh usage.
public enum MeterError: Error, Sendable, Equatable, CustomStringConvertible {
  /// No usable credentials: none stored, or the refresh token was rejected.
  case loggedOut
  /// The usage endpoint answered 401.
  case unauthorized
  /// HTTP 429; try again at the given time.
  case rateLimited(until: Date)
  /// Anything else, already phrased for display.
  case other(String)

  /// Text for the UI.
  public var description: String {
    switch self {
    case .loggedOut: "logged out"
    case .unauthorized: "unauthorized"
    case .rateLimited: "rate limited"
    case .other(let message): message
    }
  }
}

/// The outcome of one fetch: usage (possibly stale) and the reason it is not fresh.
public struct FetchResult: Sendable, Equatable {
  /// Usage to show, if any.
  public var usage: Usage?
  /// Why the usage is missing or stale.
  public var error: MeterError?

  /// Creates a result.
  public init(usage: Usage?, error: MeterError? = nil) {
    self.usage = usage
    self.error = error
  }
}
