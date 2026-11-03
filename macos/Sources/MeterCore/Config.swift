public import Foundation

/// A problem with the config file, phrased for display.
public enum ConfigError: Error, Sendable, Equatable, CustomStringConvertible {
  /// The file does not exist.
  case notFound(path: String)
  /// The file is invalid.
  case invalid(String)

  /// Text for the UI.
  public var description: String {
    switch self {
    case .notFound(let path): "No config at \(path)"
    case .invalid(let m): m
    }
  }
}

/// The parsed config: accounts and the optional refresh interval.
public struct Config: Sendable, Equatable {
  /// Accounts in file order, Claude first.
  public var accounts: [AccountSpec]
  /// The `refresh` setting, if present.
  public var refresh: TimeInterval?

  /// Creates a config.
  public init(accounts: [AccountSpec], refresh: TimeInterval? = nil) {
    self.accounts = accounts
    self.refresh = refresh
  }
}

/// Where the config lives: $XDG_CONFIG_HOME/meter/config.toml or ~/.config/meter/config.toml.
public func defaultConfigPath(home: String, xdgConfigHome: String?) -> String {
  if let x = xdgConfigHome, !x.isEmpty { return cleanPath(x + "/meter/config.toml") }
  return cleanPath(home + "/.config/meter/config.toml")
}

/// Cleans a path lexically, like Go's filepath.Clean.
public func cleanPath(_ p: String) -> String {
  if p.isEmpty { return "." }
  let rooted = p.hasPrefix("/")
  var out: [Substring] = []
  for part in p.split(separator: "/", omittingEmptySubsequences: true) {
    switch part {
    case ".": continue
    case "..":
      if let last = out.last, last != ".." {
        out.removeLast()
      } else if !rooted {
        out.append(part)
      }
    default: out.append(part)
    }
  }
  let joined = out.joined(separator: "/")
  if rooted { return "/" + joined }
  return joined.isEmpty ? "." : joined
}

/// Expands a leading ~ or ~/ to `home`.
public func expandHome(_ p: String, home: String) -> String {
  if p == "~" { return home }
  if p.hasPrefix("~/") { return cleanPath(home + "/" + p.dropFirst(2)) }
  return p
}

/// Parses a Go-style duration such as "30s", "2m" or "1h30m".
public func parseDuration(_ s: String) -> TimeInterval? {
  var rest = Substring(s)
  var sign = 1.0
  if rest.hasPrefix("-") || rest.hasPrefix("+") {
    if rest.hasPrefix("-") { sign = -1 }
    rest = rest.dropFirst()
  }
  if rest == "0" { return 0 }
  if rest.isEmpty { return nil }
  let units: [(String, Double)] = [
    ("ns", 1e-9), ("us", 1e-6), ("µs", 1e-6), ("ms", 1e-3), ("s", 1), ("m", 60), ("h", 3600),
  ]
  var total = 0.0
  while !rest.isEmpty {
    let num = rest.prefix { $0.isNumber || $0 == "." }
    guard !num.isEmpty, let value = Double(num) else { return nil }
    rest = rest.dropFirst(num.count)
    guard let unit = units.filter({ rest.hasPrefix($0.0) }).max(by: { $0.0.count < $1.0.count })
    else { return nil }
    rest = rest.dropFirst(unit.0.count)
    total += value * unit.1
  }
  return sign * total
}

/// Parses and validates config text with the same rules as the Go tool.
public func parseConfig(_ text: String, home: String) throws -> Config {
  let doc: TomlDocument
  do {
    doc = try parseToml(text)
  } catch {
    throw ConfigError.invalid("\(error)")
  }
  var refresh: TimeInterval?
  if let v = doc.root["refresh"] {
    guard case .string(let s) = v else { throw ConfigError.invalid("refresh: must be a string") }
    if !s.isEmpty {
      guard let d = parseDuration(s) else {
        throw ConfigError.invalid("refresh: invalid duration \"\(s)\"")
      }
      refresh = d
    }
  }
  var accounts: [AccountSpec] = []
  for (provider, key) in [(Provider.claude, "claude"), (Provider.codex, "codex")] {
    var seen = Set<String>()
    for (i, table) in (doc.arrays[key] ?? []).enumerated() {
      var email = ""
      var rawDir = ""
      if let v = table["email"] {
        guard case .string(let s) = v else {
          throw ConfigError.invalid("\(key) account #\(i + 1): email must be a string")
        }
        email = s
      }
      if let v = table["dir"] {
        guard case .string(let s) = v else {
          throw ConfigError.invalid("\(key) account #\(i + 1): dir must be a string")
        }
        rawDir = s
      }
      if email.isEmpty {
        throw ConfigError.invalid("\(key) account #\(i + 1): email is required")
      }
      var dir = ""
      if !rawDir.isEmpty {
        // Claude Code keys its Keychain entry on this exact string, so it must be absolute
        // and clean to match what the CLI uses.
        dir = cleanPath(expandHome(rawDir, home: home))
        guard dir.hasPrefix("/") else {
          throw ConfigError.invalid("\(email): dir \"\(rawDir)\" must be absolute or start with ~/")
        }
      }
      if !seen.insert(dir).inserted {
        throw ConfigError.invalid(
          "\(email): two \(provider.title) accounts share dir \"\(rawDir)\"")
      }
      accounts.append(AccountSpec(provider: provider, email: email, dir: dir))
    }
  }
  return Config(accounts: accounts, refresh: refresh)
}

/// Reads the config file through a `FileStore`.
public struct ConfigLoader: Sendable {
  /// The config file path.
  public let path: String
  private let home: String
  private let files: any FileStore

  /// Creates a loader.
  public init(path: String, home: String, files: any FileStore) {
    self.path = path
    self.home = home
    self.files = files
  }

  /// Loads and validates the config.
  public func load() async throws -> Config {
    let data: Data?
    do {
      data = try await files.read(path)
    } catch {
      throw ConfigError.invalid("\(path): \(error.localizedDescription)")
    }
    guard let data else { throw ConfigError.notFound(path: path) }
    guard let text = String(data: data, encoding: .utf8) else {
      throw ConfigError.invalid("\(path): not UTF-8")
    }
    do {
      return try parseConfig(text, home: home)
    } catch {
      throw ConfigError.invalid("\(path): \(error)")
    }
  }
}
