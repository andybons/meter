public import Foundation

/// A used percentage clamped to 0...100.
public func clampedPercent(_ used: Double) -> Double { min(max(used, 0), 100) }

/// How worried to look about a limit.
public enum Severity: Sendable, Equatable {
  case normal
  case warning
  case critical

  /// Warning at 75% used or more, critical at 90% used or more.
  public init(percentUsed used: Double) {
    if used >= 90 {
      self = .critical
    } else if used >= 75 {
      self = .warning
    } else {
      self = .normal
    }
  }
}

extension Usage {
  /// The use of the binding limit: the highest active limit, 0...100. `nil` when no limit
  /// is active.
  public var bindingUsed: Double? {
    guard let worst = limits.filter(\.isActive).map(\.percent).max() else { return nil }
    return clampedPercent(worst)
  }
}

/// How much is used across all accounts: what the menu bar icon and menu header show.
public struct UsageOverview: Sendable, Equatable {
  /// Mean binding-limit use over accounts that have data, 0...100; `nil` if none do.
  public var percentUsed: Int?
  /// How many accounts contributed.
  public var accountCount: Int
  /// When the most recent usage was fetched, if any was.
  public var lastUpdated: Date?

  /// Averages each account's binding-limit use.
  ///
  /// Logged-out accounts and accounts with
  /// no data are excluded.
  public init(rows: [AccountRow]) {
    let used = rows.compactMap { $0.usage?.bindingUsed }
    accountCount = used.count
    lastUpdated = rows.compactMap { $0.usage?.fetchedAt }.max()
    percentUsed = used.isEmpty ? nil : Int((used.reduce(0, +) / Double(used.count)).rounded())
  }

  /// The icon's fill, 0...1; empty when there is no data.
  public var gaugeValue: Double { Double(percentUsed ?? 0) / 100 }

  /// "38% used across 7 accounts", or "No usage yet".
  public var headline: String {
    guard let p = percentUsed else { return "No usage yet" }
    return "\(p)% used across \(accountCount) \(accountCount == 1 ? "account" : "accounts")"
  }

  /// "Updated 3m ago" or "Updated just now"; `nil` before any data.
  public func updatedText(now: Date) -> String? {
    lastUpdated.map { "Updated \(agoText($0, now: now))" }
  }

  /// The spoken value of the status item.
  public var accessibilityValue: String {
    guard let p = percentUsed else { return "No usage yet" }
    return "\(p) percent used across \(accountCount) \(accountCount == 1 ? "account" : "accounts")"
  }
}
