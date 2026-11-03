import Foundation
import MeterCore
import Synchronization
import Testing

private final class FakeSource: UsageSource, Sendable {
  let calls = Mutex(0)
  let results: Mutex<[Result<Usage, MeterError>]>
  let delay: TimeInterval

  init(_ results: [Result<Usage, MeterError>], delay: TimeInterval = 0) {
    self.results = Mutex(results)
    self.delay = delay
  }

  func fetchUsage() async throws -> Usage {
    calls.withLock { $0 += 1 }
    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    let r = results.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
    return try r.get()
  }
}

private func usage(_ plan: String) -> Usage { Usage(plan: plan, limits: []) }

private func fetcher(
  _ provider: Provider, _ source: FakeSource, _ clock: FakeClock
) -> AccountFetcher {
  AccountFetcher(
    account: AccountSpec(provider: provider, email: "a"), source: source, clock: clock)
}

@Test(arguments: [(Provider.claude, 119.0, 1), (.claude, 121, 2), (.codex, 29, 1), (.codex, 31, 2)])
func minimumGapBetweenRealFetches(provider: Provider, wait: Double, calls: Int) async {
  let clock = FakeClock()
  let src = FakeSource([.success(usage("a"))])
  let f = fetcher(provider, src, clock)
  let first = await f.fetch()
  #expect(first.usage?.fetchedAt == clock.now)
  clock.advance(wait)
  let second = await f.fetch()
  #expect(src.calls.withLock { $0 } == calls)
  #expect(second.error == nil)
  #expect(second.usage != nil)
}

@Test func retryAfterLockoutKeepsStaleDataAndSkipsServer() async {
  let clock = FakeClock()
  let until = clock.now.addingTimeInterval(400)
  let src = FakeSource([
    .success(usage("a")), .failure(.rateLimited(until: until)), .success(usage("b")),
  ])
  let f = fetcher(.claude, src, clock)
  _ = await f.fetch()
  clock.advance(130)  // past the 2 minute gap
  let limited = await f.fetch()
  #expect(src.calls.withLock { $0 } == 2)
  #expect(limited.error == .rateLimited(until: until))
  #expect(limited.usage?.plan == "a")
  clock.advance(100)  // still locked out
  let again = await f.fetch()
  #expect(src.calls.withLock { $0 } == 2)
  #expect(again.error == .rateLimited(until: until))
  #expect(again.usage?.plan == "a")
  clock.advance(200)  // lockout over
  let fresh = await f.fetch()
  #expect(src.calls.withLock { $0 } == 3)
  #expect(fresh.error == nil)
}

@Test func lockoutWithoutCacheReturnsNoUsage() async {
  let clock = FakeClock()
  let until = clock.now.addingTimeInterval(60)
  let f = fetcher(.codex, FakeSource([.failure(.rateLimited(until: until))]), clock)
  let r = await f.fetch()
  #expect(r == FetchResult(usage: nil, error: .rateLimited(until: until)))
}

@Test(arguments: [MeterError.loggedOut, .other("boom")])
func errorsAreReturnedWithoutUsageAndNotCached(error: MeterError) async {
  let clock = FakeClock()
  let src = FakeSource([.failure(error)])
  let f = fetcher(.claude, src, clock)
  #expect(await f.fetch() == FetchResult(usage: nil, error: error))
  _ = await f.fetch()
  #expect(src.calls.withLock { $0 } == 2, "errors do not start a gap")
}

@Test func invalidateForcesARealFetch() async {
  let clock = FakeClock()
  let src = FakeSource([.success(usage("a"))])
  let f = fetcher(.claude, src, clock)
  _ = await f.fetch()
  await f.invalidate()
  _ = await f.fetch()
  #expect(src.calls.withLock { $0 } == 2)
}

@Test func concurrentCallsShareOneInFlightFetch() async {
  let clock = FakeClock()
  let src = FakeSource([.success(usage("a"))], delay: 0.05)
  let f = fetcher(.claude, src, clock)
  async let a = f.fetch()
  async let b = f.fetch()
  async let c = f.fetch()
  let results = await [a, b, c]
  #expect(src.calls.withLock { $0 } == 1)
  #expect(results.allSatisfy { $0.usage?.plan == "a" })
}
