import Foundation
import MeterCore
import Synchronization
import Testing

@Test func scheduleSpacesRequestsPerHost() {
  let t0 = Date(timeIntervalSince1970: 1000)
  var s = ThrottleSchedule()
  #expect(s.reserve(host: "a", now: t0) == t0)
  #expect(s.reserve(host: "a", now: t0) == t0.addingTimeInterval(0.75))
  #expect(s.reserve(host: "a", now: t0) == t0.addingTimeInterval(1.5))
  #expect(s.reserve(host: "b", now: t0) == t0, "other hosts are independent")
  let later = t0.addingTimeInterval(10)
  #expect(s.reserve(host: "a", now: later) == later, "idle hosts do not accumulate debt")
}

@Test func throttleSleepsUntilItsSlot() async throws {
  let clock = FakeClock()
  let throttle = RequestThrottle(clock: clock)
  for _ in 0..<3 { try await throttle.waitTurn(host: "h") }
  #expect(clock.slept.withLock { $0 } == [0.75, 0.75])
}

@Test func throttledClientWaitsBeforeSending() async throws {
  let clock = FakeClock()
  let http = FakeHTTP { _ in ok("{}") }
  let client = ThrottledHTTPClient(base: http, throttle: RequestThrottle(clock: clock))
  let req = HTTPRequest(url: URL(string: "https://example.com/x")!)
  for _ in 0..<3 { _ = try await client.send(req) }
  #expect(http.requests.withLock { $0.count } == 3)
  #expect(clock.slept.withLock { $0.count } == 2)
}

@Test(arguments: [
  ("300", 300.0), (" 5 ", 5), (nil, 60), ("", 60), ("-3", 60),
  ("Tue, 14 Nov 2023 22:11:20 GMT", 60),  // in the past
  ("Tue, 14 Nov 2023 22:23:20 GMT", 600),
])
func retryAfterParsing(header: String?, want: Double) {
  #expect(retryAfter(header, now: Date(timeIntervalSince1970: 1_700_000_000)) == want)
}
