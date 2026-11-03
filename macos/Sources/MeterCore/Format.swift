public import Foundation

/// A short duration such as "4d 19h", "1h 24m", "5m", "30s" or "now".
public func compactDuration(_ d: TimeInterval) -> String {
  if d > 0 && d < 60 { return "\(Int(d))s" }
  let rounded = (d / 60).rounded() * 60
  if rounded <= 0 { return "now" }
  let hours = Int(rounded / 3600)
  let minutes = Int(rounded / 60)
  if rounded >= 86_400 { return "\(hours / 24)d \(hours % 24)h" }
  if rounded >= 3600 { return "\(hours)h \(minutes % 60)m" }
  return "\(minutes)m"
}

/// "3m ago" or "just now".
public func agoText(_ at: Date, now: Date) -> String {
  let d = now.timeIntervalSince(at)
  return d >= 60 ? "\(Int(d / 60))m ago" : "just now"
}

/// Lowercase hex of `bytes`.
public func hexString(_ bytes: some Sequence<UInt8>) -> String {
  bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
}

/// The plan name as shown: Claude's "max 20x" tier is called "Ultra"; other names are
/// title-cased word by word ("max 5x" becomes "Max 5x", "pro" becomes "Pro").
public func planDisplayName(_ raw: String) -> String {
  let words = raw.split(separator: " ").map { $0.lowercased() }
  if words == ["max", "20x"] { return "Ultra" }
  return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
}
