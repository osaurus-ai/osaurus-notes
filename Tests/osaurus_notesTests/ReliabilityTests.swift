import OsaurusPluginKit
import XCTest

@testable import osaurus_notes

final class SubprocessRunnerTests: XCTestCase {

  func testCapturesStdoutAndExitStatus() throws {
    let result = try ProcessRunner.run(
      executable: "/bin/sh", arguments: ["-c", "printf hello"], timeout: 10)
    XCTAssertEqual(result.exitStatus, 0)
    XCTAssertEqual(result.stdoutText, "hello")
    XCTAssertFalse(result.timedOut)
  }

  func testLargeOutputDoesNotDeadlock() throws {
    // 4 MB of output — far beyond the ~64 KB kernel pipe buffer.
    let result = try ProcessRunner.run(
      executable: "/bin/sh",
      arguments: ["-c", "dd if=/dev/zero bs=1024 count=4096 2>/dev/null | tr '\\0' 'x'"],
      timeout: 20)
    XCTAssertEqual(result.exitStatus, 0)
    XCTAssertEqual(result.stdoutText.count, 4 * 1024 * 1024)
  }

  func testHungProcessIsKilledAndReportedAsTimedOut() throws {
    let start = Date()
    let result = try ProcessRunner.run(
      executable: "/bin/sh", arguments: ["-c", "sleep 60"], timeout: 1)
    XCTAssertTrue(result.timedOut)
    XCTAssertLessThan(Date().timeIntervalSince(start), 30)
  }

  func testOutputIsCapped() throws {
    let result = try ProcessRunner.run(
      executable: "/bin/sh",
      arguments: ["-c", "dd if=/dev/zero bs=1024 count=64 2>/dev/null | tr '\\0' 'x'"],
      timeout: 20, maxOutputBytes: 1024)
    XCTAssertEqual(result.stdoutText.count, 1024)
  }
}

final class FieldCodingTests: XCTestCase {

  let hostileCorpus = [
    "plain",
    "colon: separated",
    "SUCCESS:Fake:true",
    "tab\there",
    "newline\nhere",
    "pipes ||| here",
    "back\\slash",
    "trailing\\",
    "unicode 🦖 — ok",
  ]

  func testRoundTrip() {
    for s in hostileCorpus {
      let encoded = encodeAppleScriptField(s)
      XCTAssertFalse(encoded.contains(":"))
      XCTAssertFalse(encoded.contains("\t"))
      XCTAssertFalse(encoded.contains("\n"))
      XCTAssertEqual(decodeAppleScriptField(encoded), s, "round-trip failed for \(s)")
    }
  }

  func testAppleScriptHandlerMatchesSwiftEncoder() throws {
    // Pure string manipulation via osascript: no app automation, no TCC.
    let script = """
      set s to "My:Folder" & tab & "x|y" & linefeed & "z\\\\w"
      return my encodeField(s)
      \(appleScriptFieldEncoderHandlers)
      """
    let result = try ProcessRunner.run(
      executable: "/usr/bin/osascript", arguments: ["-e", script], timeout: 20)
    XCTAssertEqual(result.exitStatus, 0, "osascript failed: \(result.stderrText)")

    let expectedInput = "My:Folder\tx|y\nz\\w"
    XCTAssertEqual(
      result.stdoutText.trimmingCharacters(in: .newlines), encodeAppleScriptField(expectedInput))
  }
}

final class NotesParsingTests: XCTestCase {

  func testParsesNotesWithHostileNamesAndPopulatedDates() {
    let name = "Meeting: agenda\twith|tabs"
    let content = "line1\nline2: details"
    let line = [
      encodeAppleScriptField(name),
      encodeAppleScriptField(content),
      "2026-02-13T09:30:00",
      "2026-03-01T10:00:00",
    ].joined(separator: "\t")

    let result = parseNotesScriptOutput("0\n" + line + "\n")
    XCTAssertEqual(result.partialFailureCount, 0)
    XCTAssertEqual(result.notes.count, 1)
    XCTAssertEqual(result.notes[0].name, name)
    XCTAssertEqual(result.notes[0].content, content)
    XCTAssertEqual(result.notes[0].creationDate, "2026-02-13T09:30:00")
    XCTAssertEqual(result.notes[0].modificationDate, "2026-03-01T10:00:00")
  }

  func testSurfacesPartialFailureCount() throws {
    let line = encodeAppleScriptField("ok note") + "\t" + encodeAppleScriptField("body")
    let result = parseNotesScriptOutput("3\n" + line + "\n")
    XCTAssertEqual(result.partialFailureCount, 3)
    XCTAssertEqual(result.notes.count, 1)

    // The failure count must appear in the encoded JSON result.
    let json = try JSONEncoder().encode(result)
    let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    XCTAssertEqual(obj["partial_failure_count"] as? Int, 3)
  }

  func testEmptyOutputYieldsEmptyResult() {
    let result = parseNotesScriptOutput("0\n")
    XCTAssertEqual(result.partialFailureCount, 0)
    XCTAssertTrue(result.notes.isEmpty)
  }

  func testCreateNoteResponseWithColonFolderName() {
    let folder = "Work: Projects|2026"
    let raw = "SUCCESS\t" + encodeAppleScriptField(folder) + "\tfalse"
    let parsed = parseCreateNoteResponse(raw)
    XCTAssertEqual(parsed?.folder, folder)
    XCTAssertEqual(parsed?.usedDefault, false)

    XCTAssertEqual(parseCreateNoteResponse("SUCCESS\tNotes\ttrue")?.usedDefault, true)
    XCTAssertNil(parseCreateNoteResponse("ERROR something"))
  }
}

final class ListNotesValidationTests: XCTestCase {

  func testMalformedArgsReturnInvalidArgs() {
    let tool = ListNotesTool()
    let result = tool.run(args: "not json at all")
    XCTAssertTrue(result.contains("\"kind\":\"invalid_args\""), "got: \(result)")
  }

  func testWrongTypeLimitReturnsInvalidArgs() {
    let tool = ListNotesTool()
    let result = tool.run(args: "{\"limit\": \"fifty\"}")
    XCTAssertTrue(result.contains("\"kind\":\"invalid_args\""), "got: \(result)")
  }

  func testNonPositiveLimitReturnsInvalidArgs() {
    let tool = ListNotesTool()
    for bad in ["{\"limit\": 0}", "{\"limit\": -5}"] {
      let result = tool.run(args: bad)
      XCTAssertTrue(result.contains("\"kind\":\"invalid_args\""), "got: \(result)")
    }
  }
}
