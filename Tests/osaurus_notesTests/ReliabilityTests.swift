import OsaurusPluginKit
import XCTest

@testable import osaurus_notes

final class SubprocessRunnerTests: XCTestCase {
  func testCapturesStdoutAndExitStatus() throws {
    let result = try ProcessRunner.run(
      executable: "/bin/sh",
      arguments: ["-c", "printf hello"],
      timeout: 10
    )
    XCTAssertEqual(result.exitStatus, 0)
    XCTAssertEqual(result.stdoutText, "hello")
    XCTAssertFalse(result.timedOut)
  }

  func testLargeOutputDoesNotDeadlock() throws {
    let result = try ProcessRunner.run(
      executable: "/bin/sh",
      arguments: ["-c", "dd if=/dev/zero bs=1024 count=4096 2>/dev/null | tr '\\0' 'x'"],
      timeout: 20
    )
    XCTAssertEqual(result.exitStatus, 0)
    XCTAssertEqual(result.stdoutText.count, 4 * 1024 * 1024)
  }

  func testHungProcessIsTerminated() throws {
    let start = Date()
    let result = try ProcessRunner.run(
      executable: "/bin/sh",
      arguments: ["-c", "sleep 60"],
      timeout: 1
    )
    XCTAssertTrue(result.timedOut)
    XCTAssertLessThan(Date().timeIntervalSince(start), 30)
  }
}

final class FieldCodingTests: XCTestCase {
  let hostileCorpus = [
    "plain",
    "colon: separated",
    "OK\tfake",
    "newline\nhere",
    "pipes ||| here",
    "back\\slash",
    "trailing\\",
    "unicode 🦖 — ok",
  ]

  func testRoundTrip() {
    for value in hostileCorpus {
      XCTAssertEqual(
        decodeAppleScriptField(encodeAppleScriptField(value)),
        value,
        "round-trip failed for \(value)"
      )
    }
  }

  func testAppleScriptHandlerMatchesSwiftEncoder() throws {
    let script = """
      set s to "My:Folder" & tab & "x|y" & linefeed & "z\\\\w"
      return my encodeField(s)
      \(appleScriptFieldEncoderHandlers)
      """
    let result = try ProcessRunner.run(
      executable: "/usr/bin/osascript",
      arguments: ["-e", script],
      timeout: 20
    )
    XCTAssertEqual(result.exitStatus, 0, "osascript failed: \(result.stderrText)")
    XCTAssertEqual(
      result.stdoutText.trimmingCharacters(in: .newlines),
      encodeAppleScriptField("My:Folder\tx|y\nz\\w")
    )
  }

  func testAppleScriptLiteralEscaping() {
    XCTAssertEqual(AppleScriptExecutor.escapeForAppleScript("say \"hi\""), "say \\\"hi\\\"")
    XCTAssertEqual(AppleScriptExecutor.escapeForAppleScript("c:\\path"), "c:\\\\path")
    XCTAssertEqual(AppleScriptExecutor.escapeForAppleScript("\\\""), "\\\\\\\"")
  }
}

final class NotesParsingTests: XCTestCase {
  func testParsesQueryMetadataAndSnakeCaseFields() throws {
    let row = [
      encodeAppleScriptField("x-coredata://note/123"),
      encodeAppleScriptField("Meeting: agenda"),
      encodeAppleScriptField("line 1\nline 2"),
      encodeAppleScriptField("Work: Projects"),
      "2026-02-13T09:30:00",
      "2026-03-01T10:00:00",
      "true",
    ].joined(separator: "\t")

    let result = try parseQueryNotesOutput("OK\t2\t7\n\(row)\n", offset: 5)
    XCTAssertEqual(result.returned, 1)
    XCTAssertEqual(result.total, 7)
    XCTAssertTrue(result.truncated)
    XCTAssertEqual(result.nextCursor, "6")
    XCTAssertEqual(result.partialFailureCount, 2)
    XCTAssertEqual(result.notes[0].id, "x-coredata://note/123")
    XCTAssertEqual(result.notes[0].title, "Meeting: agenda")
    XCTAssertEqual(result.notes[0].preview, "line 1\nline 2")
    XCTAssertTrue(result.notes[0].previewTruncated)
    XCTAssertEqual(result.notes[0].folder, "Work: Projects")

    let encoded = try JSONEncoder().encode(result)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    XCTAssertEqual(object["next_cursor"] as? String, "6")
    XCTAssertEqual(object["partial_failure_count"] as? Int, 2)
    let notes = try XCTUnwrap(object["notes"] as? [[String: Any]])
    XCTAssertEqual(notes[0]["preview_truncated"] as? Bool, true)
    XCTAssertEqual(notes[0]["created_at"] as? String, "2026-02-13T09:30:00")
    XCTAssertEqual(notes[0]["modified_at"] as? String, "2026-03-01T10:00:00")
  }

  func testEmptyFinalPageIsSuccessfulAndNotTruncated() throws {
    let result = try parseQueryNotesOutput("OK\t0\t3\n", offset: 3)
    XCTAssertTrue(result.notes.isEmpty)
    XCTAssertEqual(result.returned, 0)
    XCTAssertEqual(result.total, 3)
    XCTAssertFalse(result.truncated)
    XCTAssertNil(result.nextCursor)
  }

  func testParsesFullNoteBodyByID() throws {
    let output = [
      "OK",
      encodeAppleScriptField("note-id"),
      encodeAppleScriptField("Title"),
      encodeAppleScriptField("full\nbody\twith delimiters"),
      encodeAppleScriptField("Notes"),
      "2026-08-06T10:00:00",
      "2026-08-06T11:00:00",
    ].joined(separator: "\t")
    let note = try parseGetNoteOutput(output)
    XCTAssertEqual(note.id, "note-id")
    XCTAssertEqual(note.body, "full\nbody\twith delimiters")
    XCTAssertEqual(note.folder, "Notes")
  }

  func testParsesCreatedStableIDAndActualFolder() throws {
    let output =
      "OK\t" + encodeAppleScriptField("note-id") + "\t"
      + encodeAppleScriptField("Work: Projects")
    let result = try parseCreateNoteOutput(output)
    XCTAssertEqual(result, CreateNoteResult(id: "note-id", folder: "Work: Projects"))
  }

  func testMalformedScriptResponsesAreExecutionErrors() {
    XCTAssertThrowsError(try parseQueryNotesOutput("garbage", offset: 0))
    XCTAssertThrowsError(try parseGetNoteOutput("OK\ttoo-short"))
    XCTAssertThrowsError(try parseCreateNoteOutput("NOT_FOUND"))
  }
}

final class NotesArgumentParserTests: XCTestCase {
  func testDefaultsAndValidCursor() throws {
    let empty = try NotesArguments.object("{}", allowed: ["limit", "cursor"])
    XCTAssertEqual(try NotesArguments.limit(empty), NotesContract.defaultLimit)
    XCTAssertEqual(try NotesArguments.cursorOffset(empty), 0)

    let paged = try NotesArguments.object(
      #"{"limit":100,"cursor":"250"}"#,
      allowed: ["limit", "cursor"]
    )
    XCTAssertEqual(try NotesArguments.limit(paged), 100)
    XCTAssertEqual(try NotesArguments.cursorOffset(paged), 250)
  }
}
