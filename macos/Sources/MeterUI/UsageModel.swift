import AppKit
import MeterCore

/// The single source of truth: account rows, the refresh schedule and config reloads.
final class UsageModel {
  private(set) var rows: [AccountRow] = []
  private(set) var configError: ConfigError?
  private(set) var interval: RefreshInterval
  var onChange: () -> Void = {}

  private let loader: ConfigLoader
  private let makeFetcher: (AccountSpec) -> AccountFetcher
  private let settings: any SettingsStore
  private var fetchers: [AccountSpec: AccountFetcher] = [:]
  private var retries: [AccountSpec: Task<Void, Never>] = [:]
  private var loop: Task<Void, Never>?
  private var wake: Task<Void, Never>?
  private var configRefresh: TimeInterval?
  private var reloading = false

  init(
    loader: ConfigLoader, makeFetcher: @escaping (AccountSpec) -> AccountFetcher,
    settings: any SettingsStore
  ) {
    self.loader = loader
    self.makeFetcher = makeFetcher
    self.settings = settings
    self.interval = RefreshInterval.resolve(stored: settings.refreshSeconds, config: nil)
  }

  var isRefreshing: Bool { reloading || rows.contains(where: \.fetching) }

  var overview: UsageOverview { UsageOverview(rows: rows) }

  /// Fetches now, then on the interval and after every wake from sleep.
  func start() {
    refreshAll()
    restartLoop()
    wake = Task { [weak self] in
      for await _ in NSWorkspace.shared.notificationCenter.notifications(
        named: NSWorkspace.didWakeNotification)
      {
        guard let self else { return }
        self.refreshAll()
      }
    }
  }

  /// A manual refresh also restarts the auto-refresh countdown.
  func refreshNow() {
    refreshAll()
    restartLoop()
  }

  func setInterval(_ new: RefreshInterval) {
    settings.setRefreshSeconds(new.seconds)
    interval = new
    restartLoop()
    onChange()
  }

  private func restartLoop() {
    loop?.cancel()
    let seconds = interval.seconds
    loop = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled, let self else { return }
        self.refreshAll()
      }
    }
  }

  /// Rereads the config, then fetches every account that is not already fetching.
  private func refreshAll() {
    guard !reloading else { return }
    reloading = true
    onChange()
    Task { [weak self] in
      guard let self else { return }
      await self.reloadConfig()
      self.reloading = false
      for spec in self.rows.map(\.spec) { self.fetch(spec) }
      self.onChange()
    }
  }

  private func reloadConfig() async {
    do {
      let config = try await loader.load()
      configError = nil
      configRefresh = config.refresh
      if settings.refreshSeconds == nil {
        let resolved = RefreshInterval.resolve(stored: nil, config: config.refresh)
        if resolved != interval {
          interval = resolved
          restartLoop()
        }
      }
      let existing = Dictionary(rows.map { ($0.spec, $0) }, uniquingKeysWith: { a, _ in a })
      rows = config.accounts.map { existing[$0] ?? AccountRow(spec: $0) }
      let keep = Set(config.accounts)
      fetchers = fetchers.filter { keep.contains($0.key) }
      for (spec, task) in retries where !keep.contains(spec) {
        task.cancel()
        retries[spec] = nil
      }
      for spec in config.accounts where fetchers[spec] == nil {
        fetchers[spec] = makeFetcher(spec)
      }
    } catch let e as ConfigError {
      configError = e
    } catch {
      configError = .invalid(error.localizedDescription)
    }
  }

  private func fetch(_ spec: AccountSpec) {
    guard let i = rows.firstIndex(where: { $0.spec == spec }), !rows[i].fetching,
      let fetcher = fetchers[spec]
    else { return }
    rows[i].fetching = true
    retries[spec]?.cancel()
    retries[spec] = nil
    Task { [weak self] in
      let result = await fetcher.fetch()
      guard let self else { return }
      if let i = self.rows.firstIndex(where: { $0.spec == spec }) {
        self.rows[i].apply(result)
      }
      if case .rateLimited(let until) = result.error {
        self.scheduleRetry(spec, at: until)
      }
      self.onChange()
    }
  }

  /// Retry on our own once a rate-limit lockout ends.
  private func scheduleRetry(_ spec: AccountSpec, at until: Date) {
    retries[spec]?.cancel()
    retries[spec] = Task { [weak self] in
      try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow) + 1))
      guard !Task.isCancelled, let self else { return }
      self.fetch(spec)
      self.onChange()
    }
  }
}
