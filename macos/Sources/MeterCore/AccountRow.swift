public import Foundation

/// Everything the UI knows about one account.
public struct AccountRow: Sendable, Equatable {
  /// The account.
  public var spec: AccountSpec
  /// Whether a fetch is running.
  public var fetching = false
  /// The last good usage, kept through errors and rate limits.
  public var usage: Usage?
  /// Why the last fetch was not fully fresh.
  public var error: MeterError?

  /// Creates a row that has not fetched yet.
  public init(spec: AccountSpec) { self.spec = spec }

  /// Applies a fetch result: logging out clears usage; errors otherwise keep the last good one.
  public mutating func apply(_ result: FetchResult) {
    fetching = false
    error = result.error
    if result.error == .loggedOut {
      usage = nil
    } else if let u = result.usage {
      usage = u
    }
  }

  /// Whether the account needs a login.
  public var isLoggedOut: Bool { error == .loggedOut }
}

/// A line of text under an account's header.
public struct Notice: Sendable, Equatable {
  /// Tone.
  public enum Kind: Sendable, Equatable {
    case info
    case warning
    case error
  }

  /// Tone.
  public var kind: Kind
  /// The words.
  public var text: String

  /// Creates a notice.
  public init(kind: Kind, text: String) {
    self.kind = kind
    self.text = text
  }
}

/// One limit, phrased as what is used.
public struct LimitDisplay: Sendable, Equatable {
  /// "Session", "Weekly", ...
  public var label: String
  /// Share used, 0...1: the bar's fill.
  public var fraction: Double
  /// The percentage column: "47%", or "Full" at 100% so a maxed limit doesn't
  /// rely on color alone.
  public var percentText: String
  /// The reset column: "4d 19h", "now", or empty when unknown.
  public var resetText: String
  /// The whole limit as words: "47% used, resets in 4d 19h".
  public var text: String
  /// Color class by what is used.
  public var severity: Severity
  /// False for limits that do not currently apply.
  public var isActive: Bool
}

/// What the menu shows for one account.
public struct RowDisplay: Sendable, Equatable {
  /// The account label.
  public var title: String
  /// The plan as shown in its badge, e.g. "Ultra"; `nil` when unknown.
  public var plan: String?
  /// Whether a fetch for this account is running.
  public var isRefreshing: Bool
  /// Loading, logged-out, rate-limit or error line, if any.
  public var notice: Notice?
  /// The limits, if any are known.
  public var limits: [LimitDisplay]
  /// Whether to offer "Log In…".
  public var needsLogin: Bool
  /// The whole row as one spoken sentence.
  public var accessibilityLabel: String
}

extension AccountRow {
  /// The row as the menu shows it at time `now`.
  public func display(now: Date) -> RowDisplay {
    let cli = spec.provider == .codex ? "codex login" : "claude auth login"
    var notice: Notice?
    switch error {
    case .loggedOut:
      notice = Notice(kind: .warning, text: "Logged out — run `\(cli)`")
    case .rateLimited(let until):
      notice = Notice(
        kind: .warning,
        text: "Rate limited — retrying in \(compactDuration(until.timeIntervalSince(now)))")
    case .some(let e):
      notice = Notice(kind: .error, text: e.description)
    case nil:
      if usage == nil {
        notice = Notice(kind: .info, text: "Loading…")
      } else if usage?.limits.isEmpty == true {
        notice = Notice(kind: .info, text: "No limits reported")
      }
    }
    // Inactive limits (a model's weekly cap that isn't in play) are noise
    // unless they're all there is.
    let all = usage?.limits ?? []
    let shown = all.contains(where: \.isActive) ? all.filter(\.isActive) : all
    let limits = shown.map { l -> LimitDisplay in
      let used = clampedPercent(l.percent)
      let percent = Int(used.rounded())
      var reset = ""
      var text = "\(percent)% used"
      if let r = l.resetsAt {
        reset = compactDuration(r.timeIntervalSince(now))
        text += reset == "now" ? ", resets now" : ", resets in \(reset)"
      }
      return LimitDisplay(
        label: l.label, fraction: used / 100, percentText: percent >= 100 ? "Full" : "\(percent)%",
        resetText: reset, text: text, severity: Severity(percentUsed: used), isActive: l.isActive)
    }
    let plan = usage.flatMap { $0.plan.isEmpty ? nil : planDisplayName($0.plan) }
    let parts = plan.map { [$0] } ?? []
    let spoken =
      ([spec.provider.title + " " + spec.email] + parts
      + (notice.map { [$0.text] } ?? []) + limits.map { "\($0.label), \($0.text)" })
      .joined(separator: ". ")
    return RowDisplay(
      title: spec.email, plan: plan, isRefreshing: fetching, notice: notice, limits: limits,
      needsLogin: isLoggedOut, accessibilityLabel: spoken)
  }
}
