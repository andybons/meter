public import Foundation

/// A JSON document that keeps fields this tool does not know about, so a credentials blob
/// can be rewritten without losing anything.
public enum JSONValue: Sendable, Equatable, Codable {
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  /// Decodes any JSON value.
  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Int64.self) {
      self = .int(v)
    } else if let v = try? c.decode(Double.self) {
      self = .double(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([JSONValue].self) {
      self = .array(v)
    } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }

  /// Encodes the value.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .int(let v): try c.encode(v)
    case .double(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }

  /// Parses JSON text.
  public static func parse(_ data: Data) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: data)
  }

  /// Member of an object, or `nil`.
  public subscript(key: String) -> JSONValue? {
    get {
      guard case .object(let o) = self else { return nil }
      return o[key]
    }
    set {
      guard case .object(var o) = self else { return }
      o[key] = newValue
      self = .object(o)
    }
  }

  /// The string, or `nil` for any other type.
  public var string: String? {
    guard case .string(let s) = self else { return nil }
    return s
  }

  /// The number as a double, or `nil` for any other type.
  public var number: Double? {
    switch self {
    case .int(let v): Double(v)
    case .double(let v): v
    default: nil
    }
  }

  /// The boolean, or `nil` for any other type.
  public var bool: Bool? {
    guard case .bool(let b) = self else { return nil }
    return b
  }

  /// The elements, or `nil` for any other type.
  public var array: [JSONValue]? {
    guard case .array(let a) = self else { return nil }
    return a
  }

  /// Whether this is an object.
  public var isObject: Bool {
    guard case .object = self else { return false }
    return true
  }

  /// Serializes with sorted keys, like Go's encoding/json; `indent` adds two-space indentation.
  public func serialized(indent: Bool = false) -> Data {
    var out = ""
    write(into: &out, indent: indent, level: 0)
    return Data(out.utf8)
  }

  private func write(into out: inout String, indent: Bool, level: Int) {
    let pad = indent ? String(repeating: "  ", count: level + 1) : ""
    let endPad = indent ? String(repeating: "  ", count: level) : ""
    let nl = indent ? "\n" : ""
    switch self {
    case .null: out += "null"
    case .bool(let v): out += v ? "true" : "false"
    case .int(let v): out += String(v)
    case .double(let v): out += v.isFinite ? "\(v)" : "null"
    case .string(let s): out += Self.quote(s)
    case .array(let a):
      if a.isEmpty {
        out += "[]"
        return
      }
      out += "[" + nl
      for (i, v) in a.enumerated() {
        out += pad
        v.write(into: &out, indent: indent, level: level + 1)
        out += (i < a.count - 1 ? "," : "") + nl
      }
      out += endPad + "]"
    case .object(let o):
      if o.isEmpty {
        out += "{}"
        return
      }
      out += "{" + nl
      let keys = o.keys.sorted()
      for (i, k) in keys.enumerated() {
        out += pad + Self.quote(k) + (indent ? ": " : ":")
        o[k]?.write(into: &out, indent: indent, level: level + 1)
        out += (i < keys.count - 1 ? "," : "") + nl
      }
      out += endPad + "}"
    }
  }

  private static func quote(_ s: String) -> String {
    var r = "\""
    for u in s.unicodeScalars {
      switch u {
      case "\"": r += "\\\""
      case "\\": r += "\\\\"
      case "\n": r += "\\n"
      case "\r": r += "\\r"
      case "\t": r += "\\t"
      default:
        if u.value < 0x20 {
          let hex = String(u.value, radix: 16)
          r += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
        } else {
          r.unicodeScalars.append(u)
        }
      }
    }
    return r + "\""
  }
}
