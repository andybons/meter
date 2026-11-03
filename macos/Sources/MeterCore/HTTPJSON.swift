public import Foundation

/// Parses a Retry-After header (seconds or an HTTP date), defaulting to a minute.
public func retryAfter(_ value: String?, now: Date) -> TimeInterval {
  let v = (value ?? "").trimmingCharacters(in: .whitespaces)
  if let s = Int(v), s > 0 { return TimeInterval(s) }
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")
  f.timeZone = TimeZone(identifier: "GMT")
  f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
  if let d = f.date(from: v), d > now { return d.timeIntervalSince(now) }
  return 60
}

/// JSON requests with the status handling both providers share.
struct JSONClient {
  let http: any HTTPClient
  let clock: any Clock

  func get(_ url: String, headers: [String: String]) async throws -> JSONValue {
    try await send(HTTPRequest(url: try makeURL(url), headers: headers), isToken: false)
  }

  func post(_ url: String, body: [String: String]) async throws -> JSONValue {
    let data = JSONValue.object(body.mapValues { .string($0) }).serialized()
    let req = HTTPRequest(
      url: try makeURL(url), method: "POST",
      headers: ["Content-Type": "application/json"], body: data)
    return try await send(req, isToken: true)
  }

  private func makeURL(_ s: String) throws -> URL {
    guard let u = URL(string: s) else { throw MeterError.other("bad url \(s)") }
    return u
  }

  /// For token endpoints, 400 and 401 mean the refresh token is dead (logged out).
  private func send(_ req: HTTPRequest, isToken: Bool) async throws -> JSONValue {
    let resp: HTTPResponse
    do {
      resp = try await http.send(req)
    } catch let e as MeterError {
      throw e
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw MeterError.other(error.localizedDescription)
    }
    let host = req.url.host ?? ""
    switch resp.status {
    case 200:
      do {
        return try JSONValue.parse(resp.body)
      } catch {
        throw MeterError.other("\(host): invalid response")
      }
    case 400 where isToken, 401 where isToken:
      throw MeterError.loggedOut
    case 401:
      throw MeterError.unauthorized
    case 429:
      let wait = retryAfter(resp.headers["retry-after"], now: clock.now)
      throw MeterError.rateLimited(until: clock.now.addingTimeInterval(wait))
    default:
      throw MeterError.other("\(host): HTTP \(resp.status)")
    }
  }
}

/// Whether a token expiring at `expiry` should be refreshed now.
///
/// A nil expiry never expires.
func tokenExpired(_ expiry: Date?, now: Date) -> Bool {
  guard let expiry else { return false }
  return expiry.timeIntervalSince(now) < 60
}
