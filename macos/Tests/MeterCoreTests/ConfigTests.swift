import Foundation
import MeterCore
import Testing

private let home = "/Users/u"

@Test(arguments: [
  ("", "Claude Code-credentials"),
  ("/home/u/.claude-a@example.com", "Claude Code-credentials-aa24287f"),
])
func keychainService(dir: String, want: String) {
  #expect(ClaudeUsageSource.keychainService(dir: dir) == want)
}

@Test(arguments: [
  ("/a/b/", "/a/b"), ("/a//b/./c/../d", "/a/b/d"), ("/..", "/"), ("a/../..", ".."), ("", "."),
])
func clean(path: String, want: String) {
  #expect(cleanPath(path) == want)
}

@Test(arguments: [
  ("~", "/Users/u"), ("~/.claude-x/", "/Users/u/.claude-x"), ("/abs", "/abs"), ("~other", "~other"),
])
func expand(path: String, want: String) {
  #expect(expandHome(path, home: home) == want)
}

@Test(arguments: [
  ("2m", 120.0), ("30s", 30), ("1h30m", 5400), ("1.5s", 1.5), ("300ms", 0.3), ("0", 0),
])
func duration(text: String, want: Double) {
  #expect(parseDuration(text) == want)
}

@Test(arguments: ["soon", "", "5", "m", "5x"])
func badDuration(text: String) {
  #expect(parseDuration(text) == nil)
}

@Test(arguments: [
  (nil, "/Users/u/.config/meter/config.toml"),
  ("", "/Users/u/.config/meter/config.toml"),
  ("/x/cfg/", "/x/cfg/meter/config.toml"),
])
func configPath(xdg: String?, want: String) {
  #expect(defaultConfigPath(home: home, xdgConfigHome: xdg) == want)
}

@Test func parsesFullConfig() throws {
  let text = """
    # comment
    refresh = "1m"   # trailing

    [[claude]]
    email = "a@example.com"

    [[claude]]
      email = "b@example.com"
      dir = "~/.claude-b@example.com/"

    [[codex]]
    email = 'a@example.com'
    unknown = 3

    [other]
    email = "ignored"
    """
  let c = try parseConfig(text, home: home)
  #expect(c.refresh == 60)
  #expect(
    c.accounts == [
      AccountSpec(provider: .claude, email: "a@example.com"),
      AccountSpec(provider: .claude, email: "b@example.com", dir: "/Users/u/.claude-b@example.com"),
      AccountSpec(provider: .codex, email: "a@example.com"),
    ])
}

@Test func sameDirAcrossProvidersIsFine() throws {
  let text = "[[claude]]\nemail = \"a\"\ndir = \"/d\"\n[[codex]]\nemail = \"a\"\ndir = \"/d\"\n"
  #expect(try parseConfig(text, home: home).accounts.count == 2)
}

@Test(arguments: [
  ("[[claude]]\ndir = \"~/.claude-x\"\n", "claude account #1: email is required"),
  ("[[claude]]\nemail = \"a\"\ndir = \"rel\"\n", "must be absolute or start with ~/"),
  ("[[codex]]\nemail = \"a\"\n[[codex]]\nemail = \"b\"\n", "two Codex accounts share dir"),
  (
    "[[claude]]\nemail=\"a\"\ndir=\"/x\"\n[[claude]]\nemail=\"b\"\ndir=\"/x/\"\n",
    "two Claude accounts share dir \"/x/\""
  ),
  ("refresh = \"soon\"\n", "refresh: invalid duration"),
  ("refresh = 5\n", "refresh: must be a string"),
  ("[[claude]]\nemail = \"a\n", "unterminated string"),
  ("[[claude\nemail = \"a\"\n", "unterminated table header"),
  ("nonsense\n", "expected key = value"),
])
func configErrors(text: String, message: String) {
  do {
    _ = try parseConfig(text, home: home)
    Issue.record("expected an error")
  } catch {
    #expect("\(error)".contains(message), "got \(error)")
  }
}

@Test func tomlEscapes() throws {
  let c = try parseConfig("[[claude]]\nemail = \"a\\u0041\\\"b\\\\\"\n", home: home)
  #expect(c.accounts.first?.email == "aA\"b\\")
}

@Test func loaderReportsMissingAndReadsFile() async throws {
  let files = FakeFiles()
  let loader = ConfigLoader(path: "/c.toml", home: home, files: files)
  await #expect(throws: ConfigError.notFound(path: "/c.toml")) { try await loader.load() }
  try await files.writeAtomic("/c.toml", data: data("[[codex]]\nemail = \"x\"\n"))
  #expect(try await loader.load().accounts.count == 1)
  try await files.writeAtomic("/c.toml", data: data("[[codex]]\n"))
  do {
    _ = try await loader.load()
    Issue.record("expected error")
  } catch {
    #expect("\(error)".hasPrefix("/c.toml: codex account #1"))
  }
}
