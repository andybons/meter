public import Foundation

/// Sample accounts and usage for `--demo`, used for screenshots: no config
/// file, Keychain or network is touched.
public enum Demo {
  /// The sample config.
  public static let config = """
    [[claude]]
    email = "you@example.com"

    [[claude]]
    email = "you@work.example"
    dir = "~/.claude-work"

    [[claude]]
    email = "side@project.example"
    dir = "~/.claude-side"

    [[codex]]
    email = "you@example.com"

    [[codex]]
    email = "you@work.example"
    dir = "~/.codex-work"
    """

  /// The sample usage for `account`, with resets measured from `now`.
  public static func usage(for account: AccountSpec, now: Date) -> Usage {
    func limit(_ label: String, _ percent: Double, in seconds: TimeInterval) -> Limit {
      Limit(label: label, percent: percent, resetsAt: now + seconds, isActive: true)
    }
    let hour: TimeInterval = 3600
    let day = 24 * hour
    switch (account.provider, account.email) {
    case (.claude, "you@example.com"):
      return Usage(plan: "max 20x", limits: [limit("Weekly", 48, in: 3 * day + 19 * hour)])
    case (.claude, "you@work.example"):
      return Usage(
        plan: "team 5x",
        limits: [
          limit("Session", 23, in: 2 * hour + 10 * 60), limit("Weekly", 84, in: 2 * day + 4 * hour),
        ])
    case (.claude, _):
      return Usage(plan: "pro", limits: [limit("Weekly", 100, in: 3 * day + 5 * hour)])
    case (.codex, "you@example.com"):
      return Usage(plan: "pro", limits: [limit("Weekly", 53, in: 5 * day + 13 * hour)])
    case (.codex, _):
      return Usage(
        plan: "team",
        limits: [limit("Session", 44, in: 25 * 60), limit("Weekly", 63, in: 4 * day + 14 * hour)])
    }
  }
}

/// A file store holding only the demo config.
public struct DemoFileStore: FileStore {
  private let path: String

  /// Serves `Demo.config` at `path`.
  public init(configPath path: String) { self.path = path }

  /// Returns the demo config for its path and nothing for any other.
  public func read(_ path: String) async throws -> Data? {
    path == self.path ? Data(Demo.config.utf8) : nil
  }

  /// Discards writes: the demo changes nothing on disk.
  public func writeAtomic(_ path: String, data: Data) async throws {}
}

/// Usage from `Demo.usage(for:now:)`.
public struct DemoUsageSource: UsageSource {
  private let account: AccountSpec
  private let clock: any Clock

  /// Creates a source for `account`.
  public init(account: AccountSpec, clock: any Clock) {
    self.account = account
    self.clock = clock
  }

  /// Returns the account's sample usage.
  public func fetchUsage() async throws -> Usage {
    Demo.usage(for: account, now: clock.now)
  }
}
