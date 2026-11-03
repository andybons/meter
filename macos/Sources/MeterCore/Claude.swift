import CryptoKit
import Foundation

private let claudeTokenURL = "https://platform.claude.com/v1/oauth/token"
private let claudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
private let claudeUsageURL = "https://api.anthropic.com/api/oauth/usage"

/// Where a source gets usage from.
///
/// One per account.
public protocol UsageSource: Sendable {
  /// Fetches fresh usage, refreshing tokens when needed.
  func fetchUsage() async throws -> Usage
}

/// Fetches usage for one Claude Code account.
public struct ClaudeUsageSource: UsageSource {
  private let account: AccountSpec
  private let keychain: any CredentialStore
  private let json: JSONClient
  private let clock: any Clock
  private let user: String

  /// Creates a source. `user` is the Keychain account name Claude Code uses (the login name).
  public init(
    account: AccountSpec, keychain: any CredentialStore, http: any HTTPClient,
    clock: any Clock, user: String
  ) {
    self.account = account
    self.keychain = keychain
    self.json = JSONClient(http: http, clock: clock)
    self.clock = clock
    self.user = user
  }

  /// Claude Code's Keychain service name: a custom config dir adds the first 8 hex chars of
  /// sha256 of the exact dir string.
  public static func keychainService(dir: String) -> String {
    let base = "Claude Code-credentials"
    if dir.isEmpty { return base }
    let sum = SHA256.hash(data: Data(dir.utf8))
    let hex = hexString(sum)
    return base + "-" + hex.prefix(8)
  }

  private var service: String { Self.keychainService(dir: account.dir) }

  private func readBlob() async throws -> JSONValue {
    let data: Data?
    do {
      data = try await keychain.read(service: service)
    } catch {
      data = nil
    }
    guard let data else { throw MeterError.loggedOut }
    do {
      let blob = try JSONValue.parse(data)
      guard blob.isObject else { throw MeterError.other("parse credentials: not an object") }
      return blob
    } catch let e as MeterError {
      throw e
    } catch {
      throw MeterError.other("parse credentials: \(error.localizedDescription)")
    }
  }

  /// Fetches usage, refreshing the token first if it expired or the server rejects it.
  public func fetchUsage() async throws -> Usage {
    var blob = try await readBlob()
    guard let o = blob["claudeAiOauth"], !(o["accessToken"]?.string ?? "").isEmpty else {
      throw MeterError.loggedOut
    }
    // A missing expiresAt counts as the epoch, so the token is refreshed (as in the Go tool).
    let expiry = Date(timeIntervalSince1970: (o["expiresAt"]?.number ?? 0) / 1000)
    if tokenExpired(expiry, now: clock.now) { try await refresh(&blob) }
    var usage: Usage
    do {
      usage = try await fetchLimits(token: blob["claudeAiOauth"]?["accessToken"]?.string ?? "")
    } catch MeterError.unauthorized {
      try await refresh(&blob)
      usage = try await fetchLimits(token: blob["claudeAiOauth"]?["accessToken"]?.string ?? "")
    }
    usage.plan = Self.plan(blob["claudeAiOauth"] ?? o)
    return usage
  }

  /// Exchanges the refresh token and saves the result, or adopts newer stored credentials
  /// when Claude Code rotated the token meanwhile.
  private func refresh(_ blob: inout JSONValue) async throws {
    guard let o = blob["claudeAiOauth"], let rt = o["refreshToken"]?.string, !rt.isEmpty else {
      throw MeterError.loggedOut
    }
    let resp: JSONValue
    do {
      resp = try await json.post(
        claudeTokenURL,
        body: ["grant_type": "refresh_token", "refresh_token": rt, "client_id": claudeClientID])
    } catch {
      if let fresh = try? await readBlob(), let fo = fresh["claudeAiOauth"],
        fo["refreshToken"]?.string != rt
      {
        blob["claudeAiOauth"] = fo
        return
      }
      throw error
    }
    var updated = o
    updated["accessToken"] = .string(resp["access_token"]?.string ?? "")
    if let new = resp["refresh_token"]?.string, !new.isEmpty {
      updated["refreshToken"] = .string(new)
    }
    if let secs = resp["expires_in"]?.number, secs > 0 {
      let ms = (clock.now.timeIntervalSince1970 + secs) * 1000
      updated["expiresAt"] = .int(Int64(ms))
    }
    blob["claudeAiOauth"] = updated
    do {
      try await keychain.write(service: service, account: user, data: blob.serialized())
    } catch {
      throw MeterError.other("save refreshed token: \(error.localizedDescription)")
    }
  }

  private func fetchLimits(token: String) async throws -> Usage {
    let r = try await json.get(
      claudeUsageURL,
      headers: ["Authorization": "Bearer " + token, "anthropic-beta": "oauth-2025-04-20"])
    return Self.parseUsage(r)
  }

  /// Parses the usage response: `limits[]`, or the older five_hour/seven_day fields.
  static func parseUsage(_ r: JSONValue) -> Usage {
    var limits: [Limit] = []
    for l in r["limits"]?.array ?? [] {
      var label = limitLabel(kind: l["kind"]?.string ?? "", group: l["group"]?.string ?? "")
      if let name = l["scope"]?["model"]?["display_name"]?.string, !name.isEmpty {
        label = "Weekly · " + name
      }
      limits.append(
        Limit(
          label: label, percent: l["percent"]?.number ?? 0,
          resetsAt: parseDate(l["resets_at"]?.string), isActive: l["is_active"]?.bool ?? false))
    }
    if limits.isEmpty {
      for (key, label) in [("five_hour", "Session"), ("seven_day", "Weekly")] {
        guard let w = r[key], w.isObject else { continue }
        limits.append(
          Limit(
            label: label, percent: w["utilization"]?.number ?? 0,
            resetsAt: parseDate(w["resets_at"]?.string), isActive: true))
      }
    }
    return Usage(plan: "", limits: limits)
  }

  static func limitLabel(kind: String, group: String) -> String {
    if kind == "weekly_all" { return "Weekly" }
    if group == "session" || kind.contains("five_hour") || kind.contains("session") {
      return "Session"
    }
    return kind.replacingOccurrences(of: "_", with: " ")
  }

  /// "max 20x" from subscriptionType and rateLimitTier.
  static func plan(_ o: JSONValue) -> String {
    let sub = o["subscriptionType"]?.string ?? ""
    let tier = o["rateLimitTier"]?.string ?? ""
    if tier.hasSuffix("20x") { return sub + " 20x" }
    if tier.hasSuffix("5x") { return sub + " 5x" }
    return sub
  }
}

func parseDate(_ s: String?) -> Date? {
  guard let s, !s.isEmpty else { return nil }
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let d = f.date(from: s) { return d }
  f.formatOptions = [.withInternetDateTime]
  return f.date(from: s)
}
