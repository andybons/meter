import Foundation
import MeterCore
import Testing

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func limit(
  _ label: String, _ percent: Double, active: Bool = true, reset: TimeInterval? = nil
)
  -> Limit
{
  Limit(
    label: label, percent: percent, resetsAt: reset.map { now.addingTimeInterval($0) },
    isActive: active)
}

private func row(
  _ email: String = "a@example.com", provider: Provider = .claude, limits: [Limit]? = nil,
  plan: String = "max", error: MeterError? = nil, fetchedAgo: TimeInterval = 0
) -> AccountRow {
  var r = AccountRow(spec: AccountSpec(provider: provider, email: email))
  r.usage = limits.map {
    Usage(plan: plan, limits: $0, fetchedAt: now.addingTimeInterval(-fetchedAgo))
  }
  r.error = error
  return r
}

private let compactCases: [(Double, String)] = [
  (0.0, "now"), (-5, "now"), (20, "20s"), (29, "29s"), (89, "1m"), (90, "2m"), (300, "5m"),
  (3600, "1h 0m"), (5040, "1h 24m"), (86_400, "1d 0h"), (28 * 3600 + 20, "1d 4h"),
  (4 * 86_400 + 19 * 3600, "4d 19h"),
]

@Test(arguments: compactCases)
func compact(seconds: Double, want: String) {
  #expect(compactDuration(seconds) == want)
}

private let severityCases: [(Double, Severity)] = [
  (0, .normal), (74, .normal), (75, .warning), (89, .warning), (90, .critical), (100, .critical),
]

@Test(arguments: severityCases)
func severity(used: Double, want: Severity) {
  #expect(Severity(percentUsed: used) == want)
}

@Test(arguments: [(0.0, 0.0), (61, 61), (100, 100), (130, 100), (-5, 0)])
func clamped(used: Double, want: Double) {
  #expect(clampedPercent(used) == want)
}

@Test func bindingUsedIsTheHighestActiveLimit() {
  let u = Usage(plan: "", limits: [limit("S", 93), limit("W", 40), limit("M", 99, active: false)])
  #expect(u.bindingUsed == 93)
  #expect(Usage(plan: "", limits: [limit("M", 99, active: false)]).bindingUsed == nil)
  #expect(Usage(plan: "", limits: []).bindingUsed == nil)
}

@Test func overviewAveragesBindingUseOfAccountsWithData() {
  let rows = [
    row(limits: [limit("S", 40), limit("W", 20)]),  // 60 used
    row(limits: [limit("W", 36)]),  // 64 used
    row(limits: nil, error: .loggedOut),  // excluded
    row(limits: nil),  // no data: excluded
    row(limits: [], plan: ""),  // no limits: excluded
    row(error: .other("x")),  // excluded
  ]
  let o = UsageOverview(rows: rows)
  #expect(o.percentUsed == 38)
  #expect(o.accountCount == 2)
  #expect(o.headline == "38% used across 2 accounts")
  #expect(o.accessibilityValue == "38 percent used across 2 accounts")
  #expect(o.gaugeValue == 0.38)
}

@Test func overviewKeepsStaleDataThroughErrors() {
  let o = UsageOverview(rows: [row(limits: [limit("W", 50)], error: .rateLimited(until: now))])
  #expect(o.headline == "50% used across 1 account")
}

@Test(arguments: [[AccountRow](), [row(limits: nil, error: .loggedOut)]])
func overviewWithoutData(rows: [AccountRow]) {
  let o = UsageOverview(rows: rows)
  #expect(o.percentUsed == nil)
  #expect(o.headline == "No usage yet")
  #expect(o.accessibilityValue == "No usage yet")
  #expect(o.gaugeValue == 0)
}

@Test func applyKeepsStaleUsageExceptWhenLoggedOut() {
  var r = row(limits: [limit("W", 10)])
  r.fetching = true
  r.apply(FetchResult(usage: nil, error: .other("500")))
  #expect(r.usage != nil && r.error == .other("500") && !r.fetching)
  r.apply(FetchResult(usage: nil, error: .loggedOut))
  #expect(r.usage == nil && r.isLoggedOut)
  r.apply(FetchResult(usage: Usage(plan: "p", limits: []), error: nil))
  #expect(r.usage?.plan == "p" && r.error == nil)
}

@Test func displayShowsUsedInColumns() {
  let r = row(
    limits: [limit("Weekly", 47, reset: 4 * 86_400 + 19 * 3600), limit("Session", 95, reset: 10)],
    plan: "max 20x", fetchedAgo: 180)
  let d = r.display(now: now)
  #expect(d.title == "a@example.com")
  #expect(d.plan == "Ultra")
  #expect(!d.isRefreshing)
  #expect(d.notice == nil)
  #expect(d.limits.map(\.percentText) == ["47%", "95%"])
  #expect(d.limits.map(\.resetText) == ["4d 19h", "10s"])
  #expect(d.limits.map(\.text) == ["47% used, resets in 4d 19h", "95% used, resets in 10s"])
  #expect(d.limits.map(\.severity) == [.normal, .critical])
  #expect(d.limits.map(\.fraction) == [0.47, 0.95])
  #expect(!d.needsLogin)
  #expect(d.accessibilityLabel.contains("Weekly, 47% used"))
}

private let stateCases: [(MeterError?, Notice, Bool)] = [
  (nil, Notice(kind: .info, text: "Loading…"), false),
  (.loggedOut, Notice(kind: .warning, text: "Logged out — run `claude auth login`"), true),
  (
    .other("api.anthropic.com: HTTP 500"),
    Notice(kind: .error, text: "api.anthropic.com: HTTP 500"), false
  ),
  (
    .rateLimited(until: now.addingTimeInterval(180)),
    Notice(kind: .warning, text: "Rate limited — retrying in 3m"), false
  ),
]

@Test(arguments: stateCases)
func displayStatesWithoutData(
  error: MeterError?, notice: Notice, login: Bool
) {
  let r = row(limits: nil, error: error)
  let d = r.display(now: now)
  #expect(d.notice == notice)
  #expect(d.needsLogin == login)
  #expect(d.limits.isEmpty)
}

@Test func rateLimitedRowKeepsStaleLimits() {
  let r = row(
    limits: [limit("Weekly", 61)], error: .rateLimited(until: now.addingTimeInterval(250)))
  let d = r.display(now: now)
  #expect(d.notice?.text == "Rate limited — retrying in 4m")
  #expect(d.limits.map(\.text) == ["61% used"])
}

@Test func codexLoggedOutHintAndRefreshingSubtitle() {
  var r = row(provider: .codex, limits: nil, error: .loggedOut)
  #expect(r.display(now: now).notice?.text == "Logged out — run `codex login`")
  r = row(limits: [limit("W", 1)], plan: "pro")
  r.fetching = true
  #expect(r.display(now: now).plan == "Pro")
  #expect(r.display(now: now).isRefreshing)
  #expect(row(limits: []).display(now: now).notice?.text == "No limits reported")
}

@Test func claudeLoginScript() {
  let s = AccountSpec(provider: .claude, email: "a", dir: "/Users/u/.claude-it's")
  #expect(
    s.loginScript == """
      #!/bin/zsh -l
      unset CLAUDE_CONFIG_DIR CODEX_HOME ANTHROPIC_API_KEY OPENAI_API_KEY
      export CLAUDE_CONFIG_DIR='/Users/u/.claude-it'\\''s'
      claude auth login
      echo
      echo 'Done. You can close this window.'

      """)
  let d = AccountSpec(provider: .claude, email: "a")
  #expect(!d.loginScript.contains("export"))
}

@Test func codexLoginScript() {
  let s = AccountSpec(provider: .codex, email: "a", dir: "/Users/u/.codex-x")
  #expect(s.loginScript.contains("export CODEX_HOME='/Users/u/.codex-x'\n"))
  #expect(s.loginScript.contains("codex login -c 'cli_auth_credentials_store=\"file\"'\n"))
  #expect(
    s.loginScript.contains("unset CLAUDE_CONFIG_DIR CODEX_HOME ANTHROPIC_API_KEY OPENAI_API_KEY"))
}

private let intervalCases: [(Double?, Double?, Double)] = [
  (nil, nil, 120), (60, 600, 60), (45, nil, 120), (nil, 60, 60),
  (nil, 61, 120), (nil, 5, 30), (nil, 9999, 600), (nil, 0, 120),
]

@Test(arguments: intervalCases)
func intervalResolution(stored: Double?, config: Double?, want: Double) {
  #expect(RefreshInterval.resolve(stored: stored, config: config).seconds == want)
}

@Test func presets() {
  #expect(RefreshInterval.presets.map(\.seconds) == [30, 60, 120, 300, 600])
  #expect(
    RefreshInterval.presets.map(\.title) == [
      "30 seconds", "1 minute", "2 minutes", "5 minutes", "10 minutes",
    ])
}

@Test func jsonRoundTripKeepsEverything() throws {
  let src = "{\"a\":[1,2.5,\"x\",null,true],\"b\":{\"c\":1700000000000},\"d\":\"é\\n\"}"
  let v = try JSONValue.parse(data(src))
  #expect(String(data: v.serialized(), encoding: .utf8) == src)
  let pretty = String(data: v.serialized(indent: true), encoding: .utf8) ?? ""
  #expect(pretty.contains("\n  \"a\": [\n    1,"))
  #expect(try JSONValue.parse(v.serialized(indent: true)) == v)
}

@Test(arguments: [
  ("max 20x", "Ultra"), ("Max 20x", "Ultra"), ("max 5x", "Max 5x"), ("max", "Max"), ("pro", "Pro"),
  ("team", "Team"), ("team 5x", "Team 5x"), ("team 20x", "Team 20x"), ("", ""),
])
func planNames(raw: String, want: String) {
  #expect(planDisplayName(raw) == want)
}

@Test(arguments: [
  ([true, false], ["A"]),
  ([false, false], ["A", "B"]),
  ([true, true], ["A", "B"]),
])
func inactiveLimitsHiddenUnlessAllInactive(active: [Bool], want: [String]) {
  let limits = [limit("A", 10, active: active[0]), limit("B", 0, active: active[1])]
  #expect(row(limits: limits).display(now: now).limits.map(\.label) == want)
}

@Test(arguments: [(99.6, "Full"), (100, "Full"), (130, "Full"), (99.4, "99%"), (0, "0%")])
func percentColumn(used: Double, want: String) {
  #expect(row(limits: [limit("W", used)]).display(now: now).limits.first?.percentText == want)
}

@Test func overviewUpdatedText() {
  #expect(UsageOverview(rows: []).updatedText(now: now) == nil)
  let o = UsageOverview(rows: [
    row(limits: [limit("W", 1)], fetchedAgo: 30), row(limits: [limit("W", 1)], fetchedAgo: 240),
  ])
  #expect(o.updatedText(now: now) == "Updated just now")
}
