import Foundation

/// Canonical tool-result envelope expected by the Osaurus host. The host
/// classifies a result as a failure only when shaped like
/// {"ok":false,"kind":...,"retryable":...}; any other output (including a bare
/// {"error":"..."}) is auto-wrapped as a SUCCESS. Every failure path must
/// return `Envelope.failure(...)`.
enum Envelope {
    enum Kind: String {
        case invalidArgs = "invalid_args"
        case executionError = "execution_error"
        case notFound = "not_found"
        case unavailable = "unavailable"
    }
    static func failure(_ kind: Kind, _ message: String, retryable: Bool? = nil) -> String {
        let retry = retryable ?? defaultRetryable(for: kind)
        return "{\"ok\":false,\"kind\":\"\(kind.rawValue)\",\"message\":\"\(escape(message))\",\"retryable\":\(retry)}"
    }
    static func successRaw(_ jsonPayload: String) -> String { "{\"ok\":true,\"result\":\(jsonPayload)}" }
    private static func defaultRetryable(for kind: Kind) -> Bool {
        switch kind { case .invalidArgs, .executionError, .unavailable: return true; case .notFound: return false }
    }
    static func escape(_ s: String) -> String {
        var out = ""; out.reserveCapacity(s.count + 2)
        for ch in s { switch ch {
            case "\\": out += "\\\\"; case "\"": out += "\\\""; case "\n": out += "\\n"
            case "\r": out += "\\r"; case "\t": out += "\\t"
            default: if let a = ch.asciiValue, a < 0x20 { out += String(format: "\\u%04x", a) } else { out.append(ch) } } }
        return out
    }
}
