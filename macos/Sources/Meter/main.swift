import AppKit
import Foundation
import MeterCore
import MeterUI

// Composition root: the only place that knows the concrete services.
let home = NSHomeDirectory()
let env = ProcessInfo.processInfo.environment
// --demo shows sample accounts for screenshots, touching no real config,
// Keychain or network.
let demo = CommandLine.arguments.contains("--demo")
let clock = SystemClock()
let files = DiskFileStore()
let keychain = SecurityToolKeychain()
let http = ThrottledHTTPClient(
  base: URLSessionHTTPClient(), throttle: RequestThrottle(clock: clock))
let configPath = defaultConfigPath(home: home, xdgConfigHome: env["XDG_CONFIG_HOME"])
let loader = ConfigLoader(
  path: configPath, home: home,
  files: demo ? DemoFileStore(configPath: configPath) as any FileStore : files)

/// Where an account's usage comes from.
func source(for spec: AccountSpec) -> any UsageSource {
  if demo { return DemoUsageSource(account: spec, clock: clock) }
  switch spec.provider {
  case .claude:
    return ClaudeUsageSource(
      account: spec, keychain: keychain, http: http, clock: clock, user: NSUserName())
  case .codex:
    return CodexUsageSource(account: spec, home: home, files: files, http: http, clock: clock)
  }
}

let delegate = AppDelegate(
  loader: loader,
  makeFetcher: { spec in
    AccountFetcher(account: spec, source: source(for: spec), clock: clock)
  },
  settings: DefaultsSettings())
let app = NSApplication.shared
app.delegate = delegate
app.run()
