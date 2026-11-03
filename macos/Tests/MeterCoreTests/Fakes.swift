import Foundation
import MeterCore
import Synchronization

/// A clock that only moves when told to or when "sleeping".
final class FakeClock: Clock, Sendable {
  private let time: Mutex<Date>
  let slept = Mutex<[TimeInterval]>([])

  init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { time = Mutex(start) }

  var now: Date { time.withLock { $0 } }

  func advance(_ s: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(s) } }

  func sleep(for seconds: TimeInterval) async throws {
    slept.withLock { $0.append(seconds) }
    advance(seconds)
  }
}

/// Answers requests from a closure and records them.
final class FakeHTTP: HTTPClient, Sendable {
  let requests = Mutex<[HTTPRequest]>([])
  private let handler: @Sendable (HTTPRequest) throws -> HTTPResponse

  init(_ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) {
    self.handler = handler
  }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    requests.withLock { $0.append(request) }
    return try handler(request)
  }
}

/// A keychain whose successive reads can differ, and that records writes.
final class FakeKeychain: CredentialStore, Sendable {
  private let reads: Mutex<[Data?]>
  let writes = Mutex<[(service: String, account: String, data: Data)]>([])
  let services = Mutex<[String]>([])

  init(reads: [Data?]) { self.reads = Mutex(reads) }

  func read(service: String) async throws -> Data? {
    services.withLock { $0.append(service) }
    return reads.withLock { $0.count > 1 ? $0.removeFirst() : ($0.first ?? nil) }
  }

  func write(service: String, account: String, data: Data) async throws {
    writes.withLock { $0.append((service, account, data)) }
  }
}

/// An in-memory file system.
final class FakeFiles: FileStore, Sendable {
  let files: Mutex<[String: Data]>

  init(_ files: [String: Data] = [:]) { self.files = Mutex(files) }

  func read(_ path: String) async throws -> Data? { files.withLock { $0[path] } }

  func writeAtomic(_ path: String, data: Data) async throws {
    files.withLock { $0[path] = data }
  }
}

func data(_ s: String) -> Data { Data(s.utf8) }

func ok(_ s: String) -> HTTPResponse { HTTPResponse(status: 200, body: data(s)) }

func jwt(exp: Int, email: String = "") -> String {
  func b64(_ s: String) -> String {
    data(s).base64EncodedString().replacingOccurrences(of: "=", with: "")
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
  }
  return "\(b64("{}")).\(b64("{\"exp\":\(exp),\"email\":\"\(email)\"}")).sig"
}
