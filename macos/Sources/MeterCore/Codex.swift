public import Foundation

private let codexTokenURL = "https://auth.openai.com/oauth/token"
private let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
private let codexUsageURL = "https://chatgpt.com/backend-api/wham/usage"

/// Claims read from a JWT payload, unverified: used only for display and early refresh.
public struct JWTClaims: Sendable, Equatable {
  /// Expiry, if present.
  public var exp: Date?
  /// Email, or empty.
  public var email: String

  /// Decodes the payload of `token`; malformed tokens give empty claims.
  public init(token: String) {
    var exp: Date?
    var email = ""
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    if parts.count == 3 {
      var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(
        of: "_", with: "/")
      b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
      if let data = Data(base64Encoded: b64), let j = try? JSONValue.parse(data) {
        if let e = j["exp"]?.number, e != 0 { exp = Date(timeIntervalSince1970: e) }
        email = j["email"]?.string ?? ""
      }
    }
    self.exp = exp
    self.email = email
  }
}

/// Fetches usage for one Codex account.
public struct CodexUsageSource: UsageSource {
  private let account: AccountSpec
  private let home: String
  private let files: any FileStore
  private let json: JSONClient
  private let clock: any Clock

  /// Creates a source reading `<dir>/auth.json`.
  public init(
    account: AccountSpec, home: String, files: any FileStore, http: any HTTPClient,
    clock: any Clock
  ) {
    self.account = account
    self.home = home
    self.files = files
    self.json = JSONClient(http: http, clock: clock)
    self.clock = clock
  }

  private var authPath: String { account.dataDir(home: home) + "/auth.json" }

  /// Loads auth.json whole so unknown fields survive a write.
  private func readAuth() async throws -> JSONValue {
    let data: Data?
    do {
      data = try await files.read(authPath)
    } catch {
      data = nil
    }
    guard let data else { throw MeterError.loggedOut }
    let blob: JSONValue
    do {
      blob = try JSONValue.parse(data)
    } catch {
      throw MeterError.other("parse auth.json: \(error.localizedDescription)")
    }
    guard let tok = blob["tokens"], !(tok["access_token"]?.string ?? "").isEmpty else {
      throw MeterError.loggedOut
    }
    return blob
  }

  /// Fetches usage, refreshing the token first if it expired or the server rejects it.
  public func fetchUsage() async throws -> Usage {
    var blob = try await readAuth()
    var tok = blob["tokens"] ?? .null
    let expiry = JWTClaims(token: tok["access_token"]?.string ?? "").exp
    if tokenExpired(expiry, now: clock.now) { tok = try await refresh(&blob, tok) }
    do {
      return try await fetchLimits(tok)
    } catch MeterError.unauthorized {
      tok = try await refresh(&blob, tok)
      return try await fetchLimits(tok)
    }
  }

  private func refresh(_ blob: inout JSONValue, _ tok: JSONValue) async throws -> JSONValue {
    guard let rt = tok["refresh_token"]?.string, !rt.isEmpty else { throw MeterError.loggedOut }
    let r: JSONValue
    do {
      r = try await json.post(
        codexTokenURL,
        body: [
          "client_id": codexClientID, "grant_type": "refresh_token", "refresh_token": rt,
          "scope": "openid profile email",
        ])
    } catch {
      // Codex may have refreshed concurrently; prefer its newer tokens.
      if let fresh = try? await readAuth(), let ft = fresh["tokens"],
        ft["refresh_token"]?.string != rt
      {
        return ft
      }
      throw error
    }
    var updated = tok
    if let id = r["id_token"]?.string, !id.isEmpty { updated["id_token"] = .string(id) }
    updated["access_token"] = .string(r["access_token"]?.string ?? "")
    if let new = r["refresh_token"]?.string, !new.isEmpty {
      updated["refresh_token"] = .string(new)
    }
    blob["tokens"] = updated
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    blob["last_refresh"] = .string(f.string(from: clock.now))
    do {
      try await files.writeAtomic(authPath, data: blob.serialized(indent: true))
    } catch {
      throw MeterError.other("save refreshed token: \(error.localizedDescription)")
    }
    return updated
  }

  private func fetchLimits(_ tok: JSONValue) async throws -> Usage {
    var headers = [
      "Authorization": "Bearer " + (tok["access_token"]?.string ?? ""),
      "User-Agent": "codex_cli_rs",
    ]
    if let id = tok["account_id"]?.string, !id.isEmpty { headers["ChatGPT-Account-Id"] = id }
    let r = try await json.get(codexUsageURL, headers: headers)
    return Self.parseUsage(r)
  }

  static func parseUsage(_ r: JSONValue) -> Usage {
    var limits: [Limit] = []
    for key in ["primary_window", "secondary_window"] {
      guard let w = r["rate_limit"]?[key], w.isObject else { continue }
      limits.append(
        Limit(
          label: windowLabel(seconds: Int64(w["limit_window_seconds"]?.number ?? 0)),
          percent: w["used_percent"]?.number ?? 0,
          resetsAt: Date(timeIntervalSince1970: w["reset_at"]?.number ?? 0), isActive: true))
    }
    return Usage(plan: r["plan_type"]?.string ?? "", limits: limits)
  }

  /// Names a window by its length.
  public static func windowLabel(seconds: Int64) -> String {
    let hours = Double(seconds) / 3600
    if seconds == 7 * 86_400 { return "Weekly" }
    if seconds == 5 * 3600 { return "Session" }
    if seconds >= 86_400 { return "\(Int(hours / 24))d window" }
    return "\(Int(hours))h window"
  }
}
