import AppKit
import Foundation
import MeterCore
import MeterUI

// Composition root: the only place that knows the concrete services.
let home = NSHomeDirectory()
let env = ProcessInfo.processInfo.environment
let clock = SystemClock()
let files = DiskFileStore()
let keychain = SecurityToolKeychain()
let http = ThrottledHTTPClient(
  base: URLSessionHTTPClient(), throttle: RequestThrottle(clock: clock))
let loader = ConfigLoader(
  path: defaultConfigPath(home: home, xdgConfigHome: env["XDG_CONFIG_HOME"]), home: home,
  files: files)

let delegate = AppDelegate(
  loader: loader,
  makeFetcher: { spec in
    let source: any UsageSource =
      spec.provider == .claude
      ? ClaudeUsageSource(
        account: spec, keychain: keychain, http: http, clock: clock, user: NSUserName())
      : CodexUsageSource(account: spec, home: home, files: files, http: http, clock: clock)
    return AccountFetcher(account: spec, source: source, clock: clock)
  },
  settings: DefaultsSettings())
let app = NSApplication.shared
app.delegate = delegate
app.run()
