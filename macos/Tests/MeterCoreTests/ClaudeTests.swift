import Foundation
import MeterCore
import Synchronization
import Testing

private let clock = FakeClock()
private let nowMs = 1_700_000_000_000

private func blob(access: String = "AT", refresh: String = "RT", expires: Int) -> Data {
  data(
    """
    {"claudeAiOauth":{"accessToken":"\(access)","refreshToken":"\(refresh)","expiresAt":\(expires),\
    "subscriptionType":"max","rateLimitTier":"default_claude_max_20x","scopes":["a"]},"other":{"keep":true}}
    """)
}

private let usageBody = """
  {"limits":[
   {"kind":"five_hour","group":"session","percent":93,"resets_at":"2026-01-01T10:00:00.5Z","is_active":true},
   {"kind":"weekly_all","percent":40,"resets_at":"2026-01-05T10:00:00Z","is_active":true},
   {"kind":"weekly_sonnet","percent":7,"is_active":false,"scope":{"model":{"display_name":"Sonnet"}}},
   {"kind":"extra_usage_cap","percent":1}
  ]}
  """

private func source(
  _ keychain: FakeKeychain, dir: String = "",
  _ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse
) -> (ClaudeUsageSource, FakeHTTP) {
  let http = FakeHTTP(handler)
  let s = ClaudeUsageSource(
    account: AccountSpec(provider: .claude, email: "a", dir: dir), keychain: keychain, http: http,
    clock: clock, user: "tester")
  return (s, http)
}

@Test func fetchesAndParsesLimits() async throws {
  let kc = FakeKeychain(reads: [blob(expires: nowMs + 3_600_000)])
  let (s, http) = source(kc, dir: "/home/u/.claude-a@example.com") { _ in ok(usageBody) }
  let u = try await s.fetchUsage()
  #expect(u.plan == "max 20x")
  #expect(
    u.limits.map(\.label) == ["Session", "Weekly", "Weekly · Sonnet", "extra usage cap"])
  #expect(u.limits.map(\.percent) == [93, 40, 7, 1])
  #expect(u.limits.map(\.isActive) == [true, true, false, false])
  #expect(u.limits[0].resetsAt == Date(timeIntervalSince1970: 1_767_261_600.5))
  #expect(u.limits[2].resetsAt == nil)
  let req = http.requests.withLock { $0 }
  #expect(req.count == 1)
  #expect(req[0].url.absoluteString == "https://api.anthropic.com/api/oauth/usage")
  #expect(req[0].headers["Authorization"] == "Bearer AT")
  #expect(req[0].headers["anthropic-beta"] == "oauth-2025-04-20")
  #expect(kc.services.withLock { $0 } == ["Claude Code-credentials-aa24287f"])
  #expect(kc.writes.withLock { $0.isEmpty })
}

@Test func fallsBackToFiveHourSevenDay() async throws {
  let kc = FakeKeychain(reads: [blob(expires: nowMs + 3_600_000)])
  let body = """
    {"five_hour":{"utilization":12.5,"resets_at":"2026-01-01T10:00:00Z"},"seven_day":{"utilization":3}}
    """
  let (s, _) = source(kc) { _ in ok(body) }
  let u = try await s.fetchUsage()
  #expect(u.limits.map(\.label) == ["Session", "Weekly"])
  #expect(u.limits.map(\.percent) == [12.5, 3])
  #expect(u.limits.allSatisfy { $0.isActive })
}

@Test(arguments: [
  ("default_claude_max_20x", "max 20x"), ("default_claude_max_5x", "max 5x"),
  ("default_claude_pro", "max"),
])
func plans(tier: String, want: String) async throws {
  let b = data(
    "{\"claudeAiOauth\":{\"accessToken\":\"AT\",\"expiresAt\":\(nowMs + 9_999_999),\"subscriptionType\":\"max\",\"rateLimitTier\":\"\(tier)\"}}"
  )
  let (s, _) = source(FakeKeychain(reads: [b])) { _ in ok("{}") }
  let u = try await s.fetchUsage()
  #expect(u.plan == want)
}

@Test func expiredTokenIsRefreshedAndWrittenBack() async throws {
  let kc = FakeKeychain(reads: [blob(expires: nowMs + 30_000)])  // under a minute left
  let (s, http) = source(kc) { req in
    if req.method == "POST" {
      return ok("{\"access_token\":\"NEW\",\"refresh_token\":\"RT2\",\"expires_in\":3600}")
    }
    return ok(usageBody)
  }
  _ = try await s.fetchUsage()
  let reqs = http.requests.withLock { $0 }
  #expect(reqs.map(\.method) == ["POST", "GET"])
  #expect(reqs[0].url.absoluteString == "https://platform.claude.com/v1/oauth/token")
  let sent = try JSONValue.parse(reqs[0].body ?? Data())
  #expect(sent["grant_type"]?.string == "refresh_token")
  #expect(sent["refresh_token"]?.string == "RT")
  #expect(sent["client_id"]?.string == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
  #expect(reqs[1].headers["Authorization"] == "Bearer NEW")
  let writes = kc.writes.withLock { $0 }
  #expect(writes.count == 1)
  #expect(writes[0].account == "tester")
  #expect(writes[0].service == "Claude Code-credentials")
  let saved = try JSONValue.parse(writes[0].data)
  #expect(saved["claudeAiOauth"]?["accessToken"]?.string == "NEW")
  #expect(saved["claudeAiOauth"]?["refreshToken"]?.string == "RT2")
  #expect(saved["claudeAiOauth"]?["expiresAt"]?.number == Double(nowMs + 3_600_000))
  #expect(saved["claudeAiOauth"]?["scopes"]?.array?.count == 1, "unknown fields survive")
  #expect(saved["other"]?["keep"]?.bool == true)
}

@Test func missingExpiryCountsAsExpired() async throws {
  let b = data("{\"claudeAiOauth\":{\"accessToken\":\"AT\",\"refreshToken\":\"RT\"}}")
  let (s, http) = source(FakeKeychain(reads: [b])) { req in
    req.method == "POST" ? ok("{\"access_token\":\"N\"}") : ok("{}")
  }
  _ = try await s.fetchUsage()
  #expect(http.requests.withLock { $0.first?.method } == "POST")
}

@Test func unauthorizedTriggersOneRefreshAndRetry() async throws {
  let kc = FakeKeychain(reads: [blob(expires: nowMs + 3_600_000)])
  let (s, http) = source(kc) { req in
    if req.method == "POST" { return ok("{\"access_token\":\"NEW\"}") }
    return req.headers["Authorization"] == "Bearer NEW"
      ? ok(usageBody) : HTTPResponse(status: 401)
  }
  _ = try await s.fetchUsage()
  #expect(http.requests.withLock { $0.map(\.method) } == ["GET", "POST", "GET"])
  #expect(kc.writes.withLock { $0.count } == 1)
}

@Test func concurrentRotationIsAdoptedInsteadOfLoggingOut() async throws {
  let kc = FakeKeychain(reads: [
    blob(refresh: "OLD", expires: nowMs + 1000),
    blob(access: "ROTATED", refresh: "NEWER", expires: nowMs + 3_600_000),
  ])
  let (s, http) = source(kc) { req in
    req.method == "POST" ? HTTPResponse(status: 400) : ok(usageBody)
  }
  _ = try await s.fetchUsage()
  #expect(http.requests.withLock { $0.last?.headers["Authorization"] } == "Bearer ROTATED")
  #expect(kc.writes.withLock { $0.isEmpty })
}

@Test func deadRefreshTokenMeansLoggedOut() async throws {
  let kc = FakeKeychain(reads: [blob(expires: nowMs + 1000)])
  let (s, _) = source(kc) { _ in HTTPResponse(status: 401) }
  await #expect(throws: MeterError.loggedOut) { try await s.fetchUsage() }
}

@Test(arguments: [nil, data("{}"), data("{\"claudeAiOauth\":{\"accessToken\":\"\"}}")])
func noCredentialsMeansLoggedOut(stored: Data?) async throws {
  let (s, http) = source(FakeKeychain(reads: [stored])) { _ in ok("{}") }
  await #expect(throws: MeterError.loggedOut) { try await s.fetchUsage() }
  #expect(http.requests.withLock { $0.isEmpty })
}

@Test(arguments: [
  ("300", 300.0), (nil, 60), ("junk", 60), ("0", 60),
  ("Tue, 14 Nov 2023 22:17:20 GMT", 240),
])
func rateLimitUsesRetryAfter(header: String?, seconds: Double) async throws {
  let kc = FakeKeychain(reads: [blob(expires: nowMs + 3_600_000)])
  let (s, _) = source(kc) { _ in
    HTTPResponse(status: 429, headers: header.map { ["retry-after": $0] } ?? [:])
  }
  await #expect(throws: MeterError.rateLimited(until: clock.now.addingTimeInterval(seconds))) {
    try await s.fetchUsage()
  }
}

@Test func otherStatusIsAnErrorWithHost() async throws {
  let kc = FakeKeychain(reads: [blob(expires: nowMs + 3_600_000)])
  let (s, _) = source(kc) { _ in HTTPResponse(status: 500) }
  await #expect(throws: MeterError.other("api.anthropic.com: HTTP 500")) {
    try await s.fetchUsage()
  }
}
