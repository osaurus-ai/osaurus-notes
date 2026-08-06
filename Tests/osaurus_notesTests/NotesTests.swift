import OsaurusPluginKit
import XCTest

@testable import osaurus_notes

final class NotesManifestTests: XCTestCase {
  private func manifest() throws -> [String: Any] {
    try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(notesManifestJSON.utf8)) as? [String: Any]
    )
  }

  private func tools() throws -> [[String: Any]] {
    let capabilities = try XCTUnwrap(try manifest()["capabilities"] as? [String: Any])
    return try XCTUnwrap(capabilities["tools"] as? [[String: Any]])
  }

  func testManifestDeclaresVersionTwoAndExactToolSurface() throws {
    let manifest = try manifest()
    XCTAssertEqual(manifest["plugin_id"] as? String, "osaurus.notes")
    XCTAssertEqual(manifest["version"] as? String, "2.0.0")
    XCTAssertEqual(
      try tools().compactMap { $0["id"] as? String },
      ["query_notes", "get_note", "create_note"]
    )
  }

  func testEveryToolUsesAutomationAndAsk() throws {
    for tool in try tools() {
      XCTAssertEqual(tool["requirements"] as? [String], ["automation"])
      XCTAssertEqual(tool["permission_policy"] as? String, "ask")
      XCTAssertNil(tool["annotations"])
      XCTAssertNil(tool["outputSchema"])
    }
  }

  func testEverySchemaIsStrict() throws {
    for tool in try tools() {
      let schema = try XCTUnwrap(tool["parameters"] as? [String: Any])
      XCTAssertEqual(schema["type"] as? String, "object")
      XCTAssertNotNil(schema["properties"] as? [String: Any])
      XCTAssertNotNil(schema["required"] as? [String])
      XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }
  }

  func testQuerySchemaDocumentsDefaultsBoundsAndCursor() throws {
    let queryTool = try XCTUnwrap(try tools().first { $0["id"] as? String == "query_notes" })
    let schema = try XCTUnwrap(queryTool["parameters"] as? [String: Any])
    let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
    let limit = try XCTUnwrap(properties["limit"] as? [String: Any])
    XCTAssertEqual(limit["default"] as? Int, NotesContract.defaultLimit)
    XCTAssertEqual(limit["minimum"] as? Int, 1)
    XCTAssertEqual(limit["maximum"] as? Int, NotesContract.maximumLimit)
    let cursor = try XCTUnwrap(properties["cursor"] as? [String: Any])
    XCTAssertEqual(cursor["pattern"] as? String, "^[0-9]+$")
  }

  func testSkillIsPackagedOutsideRuntimeManifest() throws {
    let capabilities = try XCTUnwrap(try manifest()["capabilities"] as? [String: Any])
    XCTAssertNil(capabilities["skills"])

    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let skill = try String(
      contentsOf: repositoryRoot.appendingPathComponent("SKILL.md"),
      encoding: .utf8)
    XCTAssertTrue(skill.hasPrefix("---\nname: osaurus-notes\n"))
  }
}

final class NotesValidationTests: XCTestCase {
  private func failure(_ json: String) throws -> [String: Any] {
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    )
    XCTAssertEqual(object["ok"] as? Bool, false)
    XCTAssertEqual(object["kind"] as? String, "invalid_args")
    XCTAssertEqual(object["retryable"] as? Bool, true)
    return object
  }

  func testQueryRejectsMalformedAndUnknownArguments() throws {
    XCTAssertEqual(try failure(QueryNotesTool().run(args: "not json"))["tool"] as? String, "query_notes")
    let unknown = try failure(QueryNotesTool().run(args: #"{"unexpected":true}"#))
    XCTAssertEqual(unknown["field"] as? String, "unexpected")
  }

  func testQueryRejectsInvalidOptionalStrings() throws {
    for arguments in [
      #"{"query":""}"#,
      #"{"folder":"  "}"#,
      #"{"query":null}"#,
      #"{"folder":42}"#,
    ] {
      _ = try failure(QueryNotesTool().run(args: arguments))
    }
  }

  func testQueryRejectsOutOfRangeLimitAndInvalidCursor() throws {
    for arguments in [
      #"{"limit":0}"#,
      #"{"limit":101}"#,
      #"{"limit":2.5}"#,
      #"{"limit":true}"#,
      #"{"cursor":"next"}"#,
      #"{"cursor":1}"#,
      #"{"cursor":"99999999999999999999"}"#,
    ] {
      _ = try failure(QueryNotesTool().run(args: arguments))
    }
  }

  func testGetNoteRequiresStrictStableID() throws {
    for arguments in [
      #"{}"#,
      #"{"id":""}"#,
      #"{"id":null}"#,
      #"{"id":4}"#,
      #"{"id":"x","title":"extra"}"#,
    ] {
      let result = try failure(GetNoteTool().run(args: arguments))
      XCTAssertEqual(result["tool"] as? String, "get_note")
    }
  }

  func testCreateNoteValidatesBeforeAutomation() throws {
    for arguments in [
      #"{}"#,
      #"{"title":"","body":"x"}"#,
      #"{"title":"x","body":null}"#,
      #"{"title":"x","body":"","folder":""}"#,
      #"{"title":"x","body":"","extra":true}"#,
    ] {
      let result = try failure(CreateNoteTool().run(args: arguments))
      XCTAssertEqual(result["tool"] as? String, "create_note")
    }
  }
}

final class NotesEnvelopeTests: XCTestCase {
  func testSuccessEnvelopeIsExplicitAndCanonical() throws {
    let json = successEnvelope(CreateNoteResult(id: "note-id", folder: "Notes"), tool: "create_note")
    let envelope = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    )
    XCTAssertEqual(envelope["ok"] as? Bool, true)
    XCTAssertEqual(envelope["tool"] as? String, "create_note")
    let result = try XCTUnwrap(envelope["result"] as? [String: Any])
    XCTAssertEqual(result["id"] as? String, "note-id")
    XCTAssertEqual(result["folder"] as? String, "Notes")
  }

  func testCanonicalUnavailableKindComesFromSDK() throws {
    let json = Envelope.failure(.unavailable, "Notes unavailable", tool: "get_note")
    let envelope = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    )
    XCTAssertEqual(envelope["kind"] as? String, "unavailable")
    XCTAssertEqual(envelope["retryable"] as? Bool, true)
    XCTAssertEqual(envelope["tool"] as? String, "get_note")
  }
}
