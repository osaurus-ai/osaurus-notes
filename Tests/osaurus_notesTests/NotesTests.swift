import XCTest

@testable import osaurus_notes

final class NotesTests: XCTestCase {

  // MARK: - Manifest

  func testManifestParsesAndToolsAreWellFormed() throws {
    let data = Data(notesManifestJSON.utf8)
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let manifest = try XCTUnwrap(obj, "Manifest must be a JSON object")

    XCTAssertEqual(manifest["plugin_id"] as? String, "osaurus.notes")

    let capabilities = try XCTUnwrap(manifest["capabilities"] as? [String: Any])
    let tools = try XCTUnwrap(capabilities["tools"] as? [[String: Any]])
    XCTAssertFalse(tools.isEmpty, "Manifest must declare at least one tool")

    for tool in tools {
      let id = try XCTUnwrap(tool["id"] as? String, "Each tool must have a string \"id\"")
      XCTAssertFalse(id.isEmpty, "Tool id must be non-empty")
      let description = try XCTUnwrap(
        tool["description"] as? String, "Each tool must have a string \"description\"")
      XCTAssertFalse(description.isEmpty, "Tool description must be non-empty")
    }
  }

  func testManifestContainsExpectedToolIDs() throws {
    let data = Data(notesManifestJSON.utf8)
    let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let capabilities = try XCTUnwrap(obj["capabilities"] as? [String: Any])
    let tools = try XCTUnwrap(capabilities["tools"] as? [[String: Any]])
    let ids = Set(tools.compactMap { $0["id"] as? String })
    XCTAssertEqual(ids, ["list_notes", "search_notes", "create_note"])
  }

  // MARK: - Envelope

  func testInvalidArgsFailureRoundTrips() throws {
    let json = Envelope.failure(.invalidArgs, "x")
    XCTAssertTrue(json.hasPrefix("{\"ok\":false"), "Failure must begin with {\"ok\":false")

    let obj = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    XCTAssertEqual(obj["ok"] as? Bool, false)
    XCTAssertEqual(obj["kind"] as? String, "invalid_args")
    XCTAssertEqual(obj["retryable"] as? Bool, true)
    XCTAssertEqual(obj["message"] as? String, "x")
  }

  func testFailureDefaultRetryableByKind() throws {
    func decode(_ s: String) throws -> [String: Any] {
      try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }
    XCTAssertEqual(try decode(Envelope.failure(.executionError, "m"))["retryable"] as? Bool, true)
    XCTAssertEqual(try decode(Envelope.failure(.unavailable, "m"))["retryable"] as? Bool, true)
    XCTAssertEqual(try decode(Envelope.failure(.notFound, "m"))["retryable"] as? Bool, false)
  }

  func testFailureExplicitRetryableOverridesDefault() throws {
    let json = Envelope.failure(.unavailable, "m", retryable: false)
    let obj = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    XCTAssertEqual(obj["retryable"] as? Bool, false)
    XCTAssertEqual(obj["kind"] as? String, "unavailable")
  }

  func testFailureMessageWithSpecialCharsStaysValidJSON() throws {
    let nasty = "he said \"hi\"\npath C:\\temp\ttab"
    let json = Envelope.failure(.executionError, nasty)
    let obj = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    XCTAssertEqual(obj["message"] as? String, nasty)
  }

  func testEnvelopeEscape() {
    XCTAssertEqual(Envelope.escape("a\"b"), "a\\\"b")
    XCTAssertEqual(Envelope.escape("a\\b"), "a\\\\b")
    XCTAssertEqual(Envelope.escape("a\nb"), "a\\nb")
  }

  func testSuccessRawWrapsPayload() {
    XCTAssertEqual(Envelope.successRaw("[]"), "{\"ok\":true,\"result\":[]}")
  }

  // MARK: - AppleScript escaping helper

  func testAppleScriptEscapingEscapesBackslashThenQuote() {
    XCTAssertEqual(AppleScriptExecutor.escapeForAppleScript("say \"hi\""), "say \\\"hi\\\"")
    XCTAssertEqual(AppleScriptExecutor.escapeForAppleScript("c:\\path"), "c:\\\\path")
    // A backslash followed by a quote must not collapse into an unescaped quote.
    XCTAssertEqual(AppleScriptExecutor.escapeForAppleScript("\\\""), "\\\\\\\"")
  }
}
