public import Foundation

/// The minimum gap between requests to the same host, so refreshing every account at once
/// does not arrive as a burst.
public let requestSpacing: TimeInterval = 0.75

/// Hands out request slots per host.
///
/// Pure: the caller supplies `now`.
public struct ThrottleSchedule: Sendable, Equatable {
  private var next: [String: Date] = [:]

  /// Creates an empty schedule.
  public init() {}

  /// Reserves the next free slot for `host` and returns when it starts.
  public mutating func reserve(host: String, now: Date, spacing: TimeInterval = requestSpacing)
    -> Date
  {
    var t = next[host] ?? now
    if t < now { t = now }
    next[host] = t.addingTimeInterval(spacing)
    return t
  }
}

/// Serializes slot reservation across all accounts.
public actor RequestThrottle {
  private var schedule = ThrottleSchedule()
  private let clock: any Clock
  private let spacing: TimeInterval

  /// Creates a throttle.
  public init(clock: any Clock, spacing: TimeInterval = requestSpacing) {
    self.clock = clock
    self.spacing = spacing
  }

  /// Returns once it is this caller's turn to talk to `host`.
  public func waitTurn(host: String) async throws {
    let slot = schedule.reserve(host: host, now: clock.now, spacing: spacing)
    let wait = slot.timeIntervalSince(clock.now)
    if wait > 0 { try await clock.sleep(for: wait) }
  }
}

/// Wraps a client so every request waits for its host's slot first.
public struct ThrottledHTTPClient: HTTPClient {
  private let base: any HTTPClient
  private let throttle: RequestThrottle

  /// Creates a throttled client.
  public init(base: any HTTPClient, throttle: RequestThrottle) {
    self.base = base
    self.throttle = throttle
  }

  /// Waits for the host's slot, then sends.
  public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    try await throttle.waitTurn(host: request.url.host ?? "")
    return try await base.send(request)
  }
}
