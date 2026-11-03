import Foundation

/// A parsed TOML value: only strings are needed by the config schema.
enum TomlValue: Equatable {
  case string(String)
  case other
}

/// The parsed document: top-level keys plus arrays of tables by name.
struct TomlDocument: Equatable {
  var root: [String: TomlValue] = [:]
  var arrays: [String: [[String: TomlValue]]] = [:]
}

/// A syntax error with its 1-based line.
struct TomlError: Error, CustomStringConvertible {
  let line: Int
  let message: String
  var description: String { "line \(line): \(message)" }
}

/// Parses the TOML subset the config uses.
///
/// That is comments, top-level `key = value`, `[[name]]` array tables, and string values
/// (basic or literal). Other tables and value types are accepted and ignored, as the Go
/// decoder ignores unknown keys.
func parseToml(_ text: String) throws -> TomlDocument {
  var doc = TomlDocument()
  var current: String?
  var ignoring = false
  var n = 0
  for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
    n += 1
    let line = rawLine.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\r")))
    if line.isEmpty || line.hasPrefix("#") { continue }
    if line.hasPrefix("[[") {
      guard let end = line.range(of: "]]") else {
        throw TomlError(line: n, message: "unterminated table header")
      }
      let name = line[line.index(line.startIndex, offsetBy: 2)..<end.lowerBound]
        .trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty else { throw TomlError(line: n, message: "empty table name") }
      current = name
      ignoring = false
      doc.arrays[name, default: []].append([:])
      continue
    }
    if line.hasPrefix("[") {
      guard line.contains("]") else {
        throw TomlError(line: n, message: "unterminated table header")
      }
      current = nil
      ignoring = true
      continue
    }
    guard let eq = line.firstIndex(of: "=") else {
      throw TomlError(line: n, message: "expected key = value")
    }
    let key = line[..<eq].trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else { throw TomlError(line: n, message: "missing key") }
    let value = try parseValue(String(line[line.index(after: eq)...]), line: n)
    if ignoring { continue }
    if let current, var tables = doc.arrays[current], !tables.isEmpty {
      tables[tables.count - 1][key] = value
      doc.arrays[current] = tables
    } else {
      doc.root[key] = value
    }
  }
  return doc
}

private func parseValue(_ raw: String, line: Int) throws -> TomlValue {
  let s = raw.trimmingCharacters(in: .whitespaces)
  guard let first = s.first else { throw TomlError(line: line, message: "missing value") }
  if first == "\"" {
    var out = ""
    var chars = s.dropFirst().makeIterator()
    while let c = chars.next() {
      switch c {
      case "\"": return try finish(rest: String(Array(IteratorSequence(chars))), line: line, out)
      case "\\":
        guard let e = chars.next() else { throw TomlError(line: line, message: "bad escape") }
        switch e {
        case "n": out += "\n"
        case "t": out += "\t"
        case "r": out += "\r"
        case "\"": out += "\""
        case "\\": out += "\\"
        case "u", "U":
          let count = e == "u" ? 4 : 8
          var hex = ""
          for _ in 0..<count {
            guard let h = chars.next() else { throw TomlError(line: line, message: "bad escape") }
            hex.append(h)
          }
          guard let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) else {
            throw TomlError(line: line, message: "bad unicode escape")
          }
          out.unicodeScalars.append(u)
        default: throw TomlError(line: line, message: "bad escape \\\(e)")
        }
      default: out.append(c)
      }
    }
    throw TomlError(line: line, message: "unterminated string")
  }
  if first == "'" {
    let body = s.dropFirst()
    guard let end = body.firstIndex(of: "'") else {
      throw TomlError(line: line, message: "unterminated string")
    }
    return try finish(
      rest: String(body[body.index(after: end)...]), line: line, String(body[..<end]))
  }
  return .other
}

private func finish(rest: String, line: Int, _ value: String) throws -> TomlValue {
  let r = rest.trimmingCharacters(in: .whitespaces)
  if !r.isEmpty && !r.hasPrefix("#") {
    throw TomlError(line: line, message: "unexpected text after string")
  }
  return .string(value)
}
