public import Foundation

/// Time as an input: tests supply a fake that never really sleeps.
public protocol Clock: Sendable {
  /// The current time.
  var now: Date { get }
  /// Suspends for `seconds`, throwing on cancellation.
  func sleep(for seconds: TimeInterval) async throws
}

/// The real clock.
public struct SystemClock: Clock {
  /// Creates the clock.
  public init() {}
  /// The current time.
  public var now: Date { Date() }
  /// Suspends for `seconds`.
  public func sleep(for seconds: TimeInterval) async throws {
    try await Task.sleep(for: .seconds(seconds))
  }
}

/// Reads and writes files.
///
/// Absent files read as `nil`.
public protocol FileStore: Sendable {
  /// The file's bytes, or `nil` if it does not exist.
  func read(_ path: String) async throws -> Data?
  /// Replaces the file atomically with mode 0600, creating parent directories.
  func writeAtomic(_ path: String, data: Data) async throws
}

/// Reads and writes Claude Code's credentials blob in the macOS Keychain.
public protocol CredentialStore: Sendable {
  /// The stored secret for `service`, or `nil` if there is none.
  func read(service: String) async throws -> Data?
  /// Stores `data` for `service`, updating an existing item in place.
  func write(service: String, account: String, data: Data) async throws
}

/// A request to a usage or token endpoint.
public struct HTTPRequest: Sendable, Equatable {
  /// The target.
  public var url: URL
  /// GET or POST.
  public var method: String
  /// Header fields.
  public var headers: [String: String]
  /// The body, for POST.
  public var body: Data?

  /// Creates a request.
  public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil)
  {
    self.url = url
    self.method = method
    self.headers = headers
    self.body = body
  }
}

/// A response with lowercased header names.
public struct HTTPResponse: Sendable, Equatable {
  /// Status code.
  public var status: Int
  /// Header fields keyed by lowercased name.
  public var headers: [String: String]
  /// The body.
  public var body: Data

  /// Creates a response.
  public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.status = status
    self.headers = headers
    self.body = body
  }
}

/// Sends HTTP requests.
public protocol HTTPClient: Sendable {
  /// Sends `request` and returns whatever the server answered.
  func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
