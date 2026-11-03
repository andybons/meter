public import Foundation

/// Files on disk.
public struct DiskFileStore: FileStore {
  /// Creates the store.
  public init() {}

  /// The file's bytes, or `nil` if absent.
  public func read(_ path: String) async throws -> Data? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    return try Data(contentsOf: URL(fileURLWithPath: path))
  }

  /// Writes a temp file with mode 0600 next to `path`, then renames it over.
  public func writeAtomic(_ path: String, data: Data) async throws {
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
    guard
      FileManager.default.createFile(
        atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
    else { throw MeterError.other("cannot write \(tmp.path)") }
    do {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    } catch {
      try? FileManager.default.removeItem(at: tmp)
      throw error
    }
  }
}

/// Keychain access through /usr/bin/security, as Claude Code's own items trust that tool; the
/// Security framework would prompt for a password for every account.
public struct SecurityToolKeychain: CredentialStore {
  /// Creates the store.
  public init() {}

  /// The secret for `service`, or `nil` if the tool finds none.
  public func read(service: String) async throws -> Data? {
    let r = try await Self.run(["find-generic-password", "-s", service, "-w"])
    return r.status == 0 ? r.output : nil
  }

  /// Updates (or creates) the item, passing the secret as hex like the Go tool.
  public func write(service: String, account: String, data: Data) async throws {
    let hex = hexString(data)
    let r = try await Self.run([
      "add-generic-password", "-U", "-a", account, "-s", service, "-X", hex,
    ])
    guard r.status == 0 else { throw MeterError.other("security exited with status \(r.status)") }
  }

  private static func run(_ args: [String]) async throws -> (status: Int32, output: Data) {
    try await withCheckedThrowingContinuation { cont in
      DispatchQueue.global().async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
          try p.run()
        } catch {
          cont.resume(throwing: error)
          return
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        cont.resume(returning: (p.terminationStatus, data))
      }
    }
  }
}

/// HTTP over an ephemeral URLSession.
public struct URLSessionHTTPClient: HTTPClient {
  private let session: URLSession

  /// Creates a client with a 20 second request timeout.
  public init() {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 20
    session = URLSession(configuration: c)
  }

  /// Sends the request.
  public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    var r = URLRequest(url: request.url)
    r.httpMethod = request.method
    r.httpBody = request.body
    for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
    let (data, resp) = try await session.data(for: r)
    guard let http = resp as? HTTPURLResponse else { throw MeterError.other("no HTTP response") }
    var headers: [String: String] = [:]
    for (k, v) in http.allHeaderFields {
      if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
    }
    return HTTPResponse(status: http.statusCode, headers: headers, body: data)
  }
}
