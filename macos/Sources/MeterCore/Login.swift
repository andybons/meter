import Foundation

/// Quotes `s` for a POSIX shell.
public func shellQuote(_ s: String) -> String {
  "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

extension AccountSpec {
  /// A zsh script that runs the provider's interactive login as this account, with API-key
  /// variables removed so sign-in goes through the subscription, not API billing.
  public var loginScript: String {
    var lines = [
      "#!/bin/zsh -l",
      "unset CLAUDE_CONFIG_DIR CODEX_HOME ANTHROPIC_API_KEY OPENAI_API_KEY",
    ]
    if !dir.isEmpty { lines.append("export \(envVar)=\(shellQuote(dir))") }
    switch provider {
    case .claude:
      lines.append("claude auth login")
    case .codex:
      // Force file storage so Meter can read auth.json.
      lines.append("codex login -c \(shellQuote("cli_auth_credentials_store=\"file\""))")
    }
    lines.append("echo")
    lines.append("echo 'Done. You can close this window.'")
    return lines.joined(separator: "\n") + "\n"
  }
}
