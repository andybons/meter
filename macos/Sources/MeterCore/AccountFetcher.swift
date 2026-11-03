import Foundation

/// Fetches one account's usage while honoring the rate-limit rules: a minimum gap between
/// real requests, a Retry-After lockout that keeps stale data, and at most one fetch in flight.
public actor AccountFetcher {
  private let minGap: TimeInterval
  private let source: any UsageSource
  private let clock: any Clock
  private var cached: Usage?
  private var blockedUntil: Date?
  private var inFlight: Task<FetchResult, Never>?

  /// Creates a fetcher for `account` using `source`.
  public init(account: AccountSpec, source: any UsageSource, clock: any Clock) {
    self.minGap = account.minFetchGap
    self.source = source
    self.clock = clock
  }

  /// Returns usage, calling the server only when allowed.
  ///
  /// While rate limited, or when the
  /// last result is younger than the minimum gap, it returns the last result instead.
  public func fetch() async -> FetchResult {
    if let inFlight { return await inFlight.value }
    let now = clock.now
    if let until = blockedUntil, now < until {
      return FetchResult(usage: cached, error: .rateLimited(until: until))
    }
    if let cached, now.timeIntervalSince(cached.fetchedAt) < minGap {
      return FetchResult(usage: cached)
    }
    let task = Task { await self.perform(startedAt: now) }
    inFlight = task
    return await task.value
  }

  /// Drops the cached result so the next fetch hits the server (unless rate limited).
  public func invalidate() { cached = nil }

  private func perform(startedAt now: Date) async -> FetchResult {
    defer { inFlight = nil }
    do {
      var usage = try await source.fetchUsage()
      usage.fetchedAt = now
      cached = usage
      return FetchResult(usage: usage)
    } catch MeterError.rateLimited(let until) {
      blockedUntil = until
      return FetchResult(usage: cached, error: .rateLimited(until: until))
    } catch let e as MeterError {
      return FetchResult(usage: nil, error: e)
    } catch {
      return FetchResult(usage: nil, error: .other(error.localizedDescription))
    }
  }
}
