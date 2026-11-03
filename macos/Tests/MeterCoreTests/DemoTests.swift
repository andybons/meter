import Foundation
import MeterCore
import Testing

@Test func demoConfigLoadsAndEveryAccountHasUsage() async throws {
  let loader = ConfigLoader(
    path: "/demo/config.toml", home: "/home/u",
    files: DemoFileStore(configPath: "/demo/config.toml"))
  let config = try await loader.load()
  #expect(config.accounts.count == 5)
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  for account in config.accounts {
    #expect(!Demo.usage(for: account, now: now).limits.isEmpty)
  }
}
