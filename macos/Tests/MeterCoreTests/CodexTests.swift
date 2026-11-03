import Foundation
import MeterCore
import Synchronization
import Testing

private let clock = FakeClock()
private let now = 1_700_000_000
private let path = "/Users/u/.codex-x/auth.json"

private func auth(exp: Int, refresh: String = "RT") -> Data {
  data(
    """
    {"OPENAI_API_KEY":null,"tokens":{"access_token":"\(jwt(exp: exp))","refresh_token":"\(refresh)",\
    "id_token":"ID","account_id":"acct-1"},"last_refresh":"2023-01-01T00:00:00Z"}
    """)
}

private let usage = """
  {"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_at":1700003600},
  "secondary_window":{"used_percent":52,"limit_window_seconds":604800,"reset_at":1700100000}}}
  """

private func source(
  _ files: FakeFiles, _ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse
)
  -> (CodexUsageSource, FakeHTTP)
{
  let http = FakeHTTP(handler)
  let s = CodexUsageSource(
    account: AccountSpec(provider: .codex, email: "a", dir: "/Users/u/.codex-x"), home: "/Users/u",
    files: files, http: http, clock: clock)
  return (s, http)
}

@Test(arguments: [
  (604_800, "Weekly"), (18_000, "Session"), (172_800, "2d window"), (7200, "2h window"),
  (86_400, "1d window"),
])
func windowLabels(seconds: Int64, want: String) {
  #expect(CodexUsageSource.windowLabel(seconds: seconds) == want)
}

@Test func jwtClaims() {
  let c = JWTClaims(token: jwt(exp: 1_700_000_000, email: "a@example.com"))
  #expect(c.exp == Date(timeIntervalSince1970: 1_700_000_000))
  #expect(c.email == "a@example.com")
  // header.{"exp":1700000000,"email":"a@example.com"}.sig from the Go test
  let go = "e30.eyJleHAiOjE3MDAwMDAwMDAsImVtYWlsIjoiYUBleGFtcGxlLmNvbSJ9.x"
  #expect(JWTClaims(token: go).email == "a@example.com")
  #expect(JWTClaims(token: "nope") == JWTClaims(token: "a.b"))
  #expect(JWTClaims(token: "nope").exp == nil)
}

@Test func fetchesUsageWithHeaders() async throws {
  let files = FakeFiles([path: auth(exp: now + 3600)])
  let (s, http) = source(files) { _ in ok(usage) }
  let u = try await s.fetchUsage()
  #expect(u.plan == "pro")
  #expect(u.limits.map(\.label) == ["Session", "Weekly"])
  #expect(u.limits.map(\.percent) == [12, 52])
  #expect(u.limits[0].resetsAt == Date(timeIntervalSince1970: 1_700_003_600))
  let r = http.requests.withLock { $0 }[0]
  #expect(r.url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
  #expect(r.headers["User-Agent"] == "codex_cli_rs")
  #expect(r.headers["ChatGPT-Account-Id"] == "acct-1")
  #expect(r.headers["Authorization"]?.hasPrefix("Bearer ") == true)
}

@Test func expiredCodexTokenIsRefreshedAndWrittenBack() async throws {
  let files = FakeFiles([path: auth(exp: now + 10)])
  let (s, http) = source(files) { req in
    req.method == "POST"
      ? ok("{\"access_token\":\"NEW\",\"refresh_token\":\"RT2\",\"id_token\":\"ID2\"}") : ok(usage)
  }
  _ = try await s.fetchUsage()
  let reqs = http.requests.withLock { $0 }
  #expect(reqs.map(\.method) == ["POST", "GET"])
  #expect(reqs[0].url.absoluteString == "https://auth.openai.com/oauth/token")
  let sent = try JSONValue.parse(reqs[0].body ?? Data())
  #expect(sent["client_id"]?.string == "app_EMoamEEZ73f0CkXaXp7hrann")
  #expect(sent["scope"]?.string == "openid profile email")
  #expect(reqs[1].headers["Authorization"] == "Bearer NEW")
  let saved = try JSONValue.parse(try #require(await files.read(path)))
  #expect(saved["tokens"]?["access_token"]?.string == "NEW")
  #expect(saved["tokens"]?["refresh_token"]?.string == "RT2")
  #expect(saved["tokens"]?["id_token"]?.string == "ID2")
  #expect(saved["tokens"]?["account_id"]?.string == "acct-1")
  #expect(saved["last_refresh"]?.string?.hasPrefix("2023-11-14T22:13:20") == true)
  #expect(saved["OPENAI_API_KEY"] == .null)
}

@Test func unauthorizedTriggersRefreshAndRetry() async throws {
  let files = FakeFiles([path: auth(exp: now + 3600)])
  let (s, http) = source(files) { req in
    if req.method == "POST" { return ok("{\"access_token\":\"NEW\"}") }
    return req.headers["Authorization"] == "Bearer NEW" ? ok(usage) : HTTPResponse(status: 401)
  }
  _ = try await s.fetchUsage()
  #expect(http.requests.withLock { $0.map(\.method) } == ["GET", "POST", "GET"])
}

@Test func concurrentRefreshByCodexIsAdopted() async throws {
  let files = FakeFiles([path: auth(exp: now + 10, refresh: "OLD")])
  let (s, http) = source(files) { req in
    if req.method == "POST" {
      // Codex rotates the file while our refresh is failing.
      files.files.withLock { $0[path] = auth(exp: now + 3600, refresh: "NEWER") }
      return HTTPResponse(status: 400)
    }
    return ok(usage)
  }
  #expect(try await s.fetchUsage().limits.count == 2)
  #expect(http.requests.withLock { $0.map(\.method) } == ["POST", "GET"])
}

@Test(arguments: [nil, data("{}"), data("{\"tokens\":{\"access_token\":\"\"}}")])
func missingOrEmptyAuthIsLoggedOut(stored: Data?) async throws {
  let files = FakeFiles(stored.map { [path: $0] } ?? [:])
  let (s, _) = source(files) { _ in ok(usage) }
  await #expect(throws: MeterError.loggedOut) { try await s.fetchUsage() }
}

@Test func defaultDirUsesDotCodex() async throws {
  let files = FakeFiles(["/Users/u/.codex/auth.json": auth(exp: now + 3600)])
  let http = FakeHTTP { _ in ok(usage) }
  let s = CodexUsageSource(
    account: AccountSpec(provider: .codex, email: "a"), home: "/Users/u", files: files, http: http,
    clock: clock)
  #expect(try await s.fetchUsage().limits.count == 2)
}
