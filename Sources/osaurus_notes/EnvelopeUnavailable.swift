import OsaurusPluginKit

// MARK: - Plugin-specific "unavailable" failure kind

/// This plugin's wave-1 wire contract includes an `"unavailable"` failure
/// kind (Notes app not running / automation permission denied) that is not
/// part of the SDK's canonical kind set. The overload below preserves that
/// exact wire shape — including its default retryable policy (true) — on top
/// of the SDK envelope; all canonical kinds go through the SDK directly.
extension Envelope {
  enum UnavailableKind: String {
    case unavailable
  }

  static func failure(
    _ kind: UnavailableKind, _ message: String, retryable: Bool? = nil
  ) -> String {
    let retry = retryable ?? true
    return
      "{\"ok\":false,\"kind\":\"\(kind.rawValue)\",\"message\":\"\(escape(message))\",\"retryable\":\(retry)}"
  }
}
