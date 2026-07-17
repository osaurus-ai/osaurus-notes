import Foundation

// MARK: - Models

struct Note: Codable {
  let name: String
  let content: String
  let creationDate: String?
  let modificationDate: String?
}

struct NotesListResult: Codable {
  let notes: [Note]
  /// Number of notes that could not be read (per-note AppleScript failures).
  /// Nonzero means the list is incomplete.
  let partialFailureCount: Int

  enum CodingKeys: String, CodingKey {
    case notes
    case partialFailureCount = "partial_failure_count"
  }
}

struct CreateNoteResult: Codable {
  let success: Bool
  let note: Note?
  let message: String?
  let folderName: String?
  let usedDefaultFolder: Bool?
}

struct FolderNotesResult: Codable {
  let success: Bool
  let notes: [Note]?
  let message: String?
}

// MARK: - AppleScript Helper

class AppleScriptExecutor {
  static let timeoutSeconds: TimeInterval = 30

  enum ScriptResult {
    case success(String)
    /// A ready-to-return canonical failure envelope.
    case failure(String)
  }

  /// Run an AppleScript via the shared subprocess runner (`/usr/bin/osascript`):
  /// output is drained concurrently, execution is bounded by `timeoutSeconds`,
  /// and captured output is capped. The previous synchronous `NSAppleScript`
  /// execution could hang the caller forever if Notes never responded.
  static func runScript(_ source: String) -> ScriptResult {
    let result: SubprocessResult
    do {
      result = try runSubprocess(
        executable: "/usr/bin/osascript", arguments: ["-e", source],
        timeout: timeoutSeconds)
    } catch {
      return .failure(
        Envelope.failure(
          .unavailable, "Failed to execute AppleScript: \(error.localizedDescription)",
          retryable: false))
    }

    if result.timedOut {
      return .failure(
        Envelope.failure(
          .timeout,
          "AppleScript did not finish within \(Int(timeoutSeconds)) seconds and was terminated. Notes may be busy — try again."
        ))
    }

    if result.terminationStatus != 0 {
      let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      let lower = stderr.lowercased()
      if lower.contains("not allowed") || lower.contains("not authorized")
        || lower.contains("permission")
      {
        return .failure(
          Envelope.failure(
            .unavailable,
            "Automation permission denied for Notes. Grant access in System Settings → Privacy & Security → Automation.",
            retryable: false))
      }
      return .failure(
        Envelope.failure(
          .unavailable,
          "AppleScript against Notes failed: \(stderr.isEmpty ? "unknown error" : stderr). The Notes app may not be running or permission was denied.",
          retryable: false))
    }

    return .success(result.stdout)
  }

  /// Escapes a string so it can be safely embedded inside an AppleScript
  /// double-quoted string literal. Backslashes must be escaped first, then
  /// double quotes, otherwise interpolated user input can break out of the
  /// literal and corrupt the script.
  static func escapeForAppleScript(_ s: String) -> String {
    return
      s
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }

}

// MARK: - Tools

protocol Tool {
  var id: String { get }
  var description: String { get }
  var parameters: String { get }
  var requirements: [String] { get }
  /// opt-in flag: when true, this tool appears in the dashboard's add-widget picker
  var widget: Bool { get }
  func run(args: String) -> String
}

extension Tool {
  var widget: Bool { false }
}

// Tool Definitions

struct ListNotesTool: Tool {
  let id = "list_notes"
  let widget = true
  let description = "Get all notes from Notes app (limited count)"
  let parameters = """
    {
        "type": "object",
        "properties": {
            "limit": {
                "type": "integer",
                "description": "Maximum number of notes to return (default: 50)"
            }
        }
    }
    """

  struct Args: Decodable {
    let limit: Int?
  }

  var requirements: [String] {
    return ["notes"]
  }

  func run(args: String) -> String {
    var limit = 50
    let trimmedArgs = args.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedArgs.isEmpty {
      guard let data = trimmedArgs.data(using: .utf8),
        let input = try? JSONDecoder().decode(Args.self, from: data)
      else {
        return Envelope.failure(
          .invalidArgs, "Invalid arguments: expected an object with an optional integer \"limit\".")
      }
      if let requested = input.limit {
        guard requested >= 1 else {
          return Envelope.failure(
            .invalidArgs, "Invalid arguments: \"limit\" must be a positive integer (got \(requested)).")
        }
        limit = min(requested, 500)
      }
    }
    let maxPreview = 200

    let script = """
      tell application "Notes"
          set output to ""
          set failCount to 0
          set noteCount to 0

          set allNotes to notes

          repeat with i from 1 to (count of allNotes)
              if noteCount >= \(limit) then exit repeat

              try
                  set currentNote to item i of allNotes
                  set noteName to name of currentNote
                  set noteContent to plaintext of currentNote
                  set dc to creation date of currentNote
                  set dm to modification date of currentNote

                  if (length of noteContent) > \(maxPreview) then
                      set noteContent to (characters 1 thru \(maxPreview) of noteContent) as string
                      set noteContent to noteContent & "..."
                  end if

                  set output to output & my encodeField(noteName) & tab & my encodeField(noteContent) & tab & (dc as «class isot» as string) & tab & (dm as «class isot» as string) & linefeed
                  set noteCount to noteCount + 1
              on error
                  set failCount to failCount + 1
              end try
          end repeat

          return (failCount as text) & linefeed & output
      end tell
      \(appleScriptFieldEncoderHandlers)
      """

    switch AppleScriptExecutor.runScript(script) {
    case .failure(let envelope):
      return envelope
    case .success(let output):
      let result = parseNotesScriptOutput(output)
      guard let json = try? JSONEncoder().encode(result),
        let jsonString = String(data: json, encoding: .utf8)
      else {
        return Envelope.failure(.executionError, "Failed to encode notes result")
      }
      return jsonString
    }
  }
}

/// Parse tab-delimited, field-encoded notes output. The first line is the
/// per-note failure count; each subsequent line is
/// `name<tab>content<tab>creationDate<tab>modificationDate`.
func parseNotesScriptOutput(_ output: String) -> NotesListResult {
  let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  guard !lines.isEmpty else {
    return NotesListResult(notes: [], partialFailureCount: 0)
  }
  let failCount = Int(lines[0].trimmingCharacters(in: .whitespaces)) ?? 0
  var notes: [Note] = []
  for line in lines.dropFirst() {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2 else { continue }
    let created = parts.count >= 3 && !parts[2].isEmpty ? parts[2] : nil
    let modified = parts.count >= 4 && !parts[3].isEmpty ? parts[3] : nil
    notes.append(
      Note(
        name: decodeAppleScriptField(parts[0]),
        content: decodeAppleScriptField(parts[1]),
        creationDate: created,
        modificationDate: modified))
  }
  return NotesListResult(notes: notes, partialFailureCount: failCount)
}

struct SearchNotesTool: Tool {
  let id = "search_notes"
  let description = "Find notes by search text"
  let parameters = """
    {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": "Text to search for in notes"
            }
        },
        "required": ["query"]
    }
    """

  struct Args: Decodable {
    let query: String
  }

  var requirements: [String] {
    return ["notes"]
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return Envelope.failure(.invalidArgs, "Invalid arguments: expected an object with a string \"query\".")
    }

    let trimmedQuery = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else {
      return Envelope.failure(.invalidArgs, "Invalid arguments: \"query\" must be a non-empty string.")
    }

    let searchTerm = AppleScriptExecutor.escapeForAppleScript(input.query.lowercased())
    let maxNotes = 50
    let maxPreview = 200

    let script = """
      tell application "Notes"
          set output to ""
          set failCount to 0
          set noteCount to 0
          set searchTerm to "\(searchTerm)"

          set allNotes to notes

          repeat with i from 1 to (count of allNotes)
              if noteCount >= \(maxNotes) then exit repeat

              try
                  set currentNote to item i of allNotes
                  set noteName to name of currentNote
                  set noteContent to plaintext of currentNote

                  if (noteName contains searchTerm) or (noteContent contains searchTerm) then
                      set dc to creation date of currentNote
                      set dm to modification date of currentNote
                      if (length of noteContent) > \(maxPreview) then
                          set noteContent to (characters 1 thru \(maxPreview) of noteContent) as string
                          set noteContent to noteContent & "..."
                      end if

                      set output to output & my encodeField(noteName) & tab & my encodeField(noteContent) & tab & (dc as «class isot» as string) & tab & (dm as «class isot» as string) & linefeed
                      set noteCount to noteCount + 1
                  end if
              on error
                  set failCount to failCount + 1
              end try
          end repeat

          return (failCount as text) & linefeed & output
      end tell
      \(appleScriptFieldEncoderHandlers)
      """

    switch AppleScriptExecutor.runScript(script) {
    case .failure(let envelope):
      return envelope
    case .success(let output):
      let result = parseNotesScriptOutput(output)
      guard let json = try? JSONEncoder().encode(result),
        let jsonString = String(data: json, encoding: .utf8)
      else {
        return Envelope.failure(.executionError, "Failed to encode notes result")
      }
      return jsonString
    }
  }
}

struct CreateNoteTool: Tool {
  let id = "create_note"
  let description = "Create a new note"
  let parameters = """
    {
        "type": "object",
        "properties": {
            "title": { "type": "string" },
            "body": { "type": "string" },
            "folder": { "type": "string", "description": "Folder name (default: Claude)" }
        },
        "required": ["title", "body"]
    }
    """

  struct Args: Decodable {
    let title: String
    let body: String
    let folder: String?
  }

  var requirements: [String] {
    return ["notes"]
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return Envelope.failure(
        .invalidArgs,
        "Invalid arguments: expected an object with string \"title\" and \"body\".")
    }

    let title = input.title
    let body = input.body
    let folderName = input.folder ?? "Claude"

    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return Envelope.failure(.invalidArgs, "Invalid arguments: \"title\" must be a non-empty string.")
    }

    // Use temp file for body content to handle special characters correctly
    let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent(
      "note-content-\(UUID().uuidString).txt")
    do {
      try body.write(to: tmpFile, atomically: true, encoding: .utf8)
    } catch {
      return Envelope.failure(.executionError, "Failed to write temporary file: \(error.localizedDescription)")
    }

    defer {
      try? FileManager.default.removeItem(at: tmpFile)
    }

    let escapedTitle = AppleScriptExecutor.escapeForAppleScript(title)
    let escapedFolder = AppleScriptExecutor.escapeForAppleScript(folderName)
    let tmpPath = tmpFile.path

    let script = """
      tell application "Notes"
          set targetFolder to null
          set folderFound to false
          set actualFolderName to "\(escapedFolder)"

          try
              set allFolders to folders
              repeat with currentFolder in allFolders
                  if name of currentFolder is "\(escapedFolder)" then
                      set targetFolder to currentFolder
                      set folderFound to true
                      exit repeat
                  end if
              end repeat
          on error
          end try

          if not folderFound and ("\(escapedFolder)" is "Claude" or "\(escapedFolder)" is "Test-Claude") then
              try
                  make new folder with properties {name:"\(escapedFolder)"}
                  set allFolders to folders
                  repeat with currentFolder in allFolders
                      if name of currentFolder is "\(escapedFolder)" then
                          set targetFolder to currentFolder
                          set folderFound to true
                          set actualFolderName to "\(escapedFolder)"
                          exit repeat
                      end if
                  end repeat
              on error
                  set actualFolderName to "Notes"
              end try
          end if

          set noteContent to read file POSIX file "\(tmpPath)" as «class utf8»

          if folderFound and targetFolder is not null then
              make new note at targetFolder with properties {name:"\(escapedTitle)", body:noteContent}
              return "SUCCESS" & tab & my encodeField(actualFolderName) & tab & "false"
          else
              make new note with properties {name:"\(escapedTitle)", body:noteContent}
              return "SUCCESS" & tab & my encodeField("Notes") & tab & "true"
          end if
      end tell
      \(appleScriptFieldEncoderHandlers)
      """

    let result: String
    switch AppleScriptExecutor.runScript(script) {
    case .failure(let envelope):
      return envelope
    case .success(let output):
      result = output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if let parsed = parseCreateNoteResponse(result) {
      let resultObj = CreateNoteResult(
        success: true,
        note: Note(name: title, content: body, creationDate: nil, modificationDate: nil),
        message: nil,
        folderName: parsed.folder,
        usedDefaultFolder: parsed.usedDefault
      )

      if let json = try? JSONEncoder().encode(resultObj),
        let jsonStr = String(data: json, encoding: .utf8)
      {
        return jsonStr
      }
    }

    return Envelope.failure(.executionError, "Failed to parse result: \(result)")
  }
}

/// Parse the tab-delimited create_note response
/// (`SUCCESS<tab><encoded folder><tab><usedDefault>`). The folder name is
/// field-encoded so names containing ":" or tabs cannot corrupt the response.
func parseCreateNoteResponse(_ raw: String) -> (folder: String, usedDefault: Bool)? {
  let parts = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
  guard parts.first == "SUCCESS" else { return nil }
  let folder = parts.count > 1 ? decodeAppleScriptField(parts[1]) : "Notes"
  let usedDefault = parts.count > 2 ? (parts[2] == "true") : false
  return (folder: folder, usedDefault: usedDefault)
}

// MARK: - Manifest

/// The canonical list of tools this plugin exposes. Declared at file scope so
/// both the plugin context and the test target can reference it.
let notesTools: [Tool] = [
  ListNotesTool(),
  SearchNotesTool(),
  CreateNoteTool(),
]

/// Builds the plugin manifest JSON from a list of tools. Extracted to file
/// scope (out of the C ABI closure) so it is unit-testable.
func buildNotesManifestJSON(tools: [Tool] = notesTools) -> String {
  let toolsJson = tools.map { tool -> String in
    let requirementsJson =
      "[" + tool.requirements.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    let widgetField = tool.widget ? "\"widget\": true," : ""
    return """
      {
          "id": "\(tool.id)",
          \(widgetField)
          "description": "\(tool.description)",
          "parameters": \(tool.parameters),
          "requirements": \(requirementsJson),
          "permission_policy": "ask"
      }
      """
  }.joined(separator: ",")

  return """
    {
      "plugin_id": "osaurus.notes",
      "name": "Apple Notes",
      "version": "1.0.4",
      "description": "Integration with Apple Notes",
      "license": "MIT",
      "authors": ["Dinoki Labs"],
      "min_macos": "13.0",
      "min_osaurus": "0.5.0",
      "capabilities": {
        "tools": [
          \(toolsJson)
        ]
      }
    }
    """
}

/// The fully-rendered plugin manifest JSON.
let notesManifestJSON: String = buildNotesManifestJSON()

// MARK: - C ABI surface

// Opaque context
private typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

// Function pointers
private typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
private typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
private typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?
private typealias osr_invoke_t =
  @convention(c) (
    osr_plugin_ctx_t?,
    UnsafePointer<CChar>?,  // type
    UnsafePointer<CChar>?,  // id
    UnsafePointer<CChar>?  // payload
  ) -> UnsafePointer<CChar>?

private struct osr_plugin_api {
  var free_string: osr_free_string_t?
  var `init`: osr_init_t?
  var destroy: osr_destroy_t?
  var get_manifest: osr_get_manifest_t?
  var invoke: osr_invoke_t?
}

// Context state
private class PluginContext {
  let tools: [String: Tool]

  init() {
    var dict: [String: Tool] = [:]
    for t in notesTools {
      dict[t.id] = t
    }
    self.tools = dict
  }
}

// Helper to return C strings
private func makeCString(_ s: String) -> UnsafePointer<CChar>? {
  guard let ptr = strdup(s) else { return nil }
  return UnsafePointer(ptr)
}

// API Implementation
private var api: osr_plugin_api = {
  var api = osr_plugin_api()

  api.free_string = { ptr in
    if let p = ptr { free(UnsafeMutableRawPointer(mutating: p)) }
  }

  api.`init` = {
    let ctx = PluginContext()
    return Unmanaged.passRetained(ctx).toOpaque()
  }

  api.destroy = { ctxPtr in
    guard let ctxPtr = ctxPtr else { return }
    Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
  }

  api.get_manifest = { ctxPtr in
    guard ctxPtr != nil else { return nil }
    return makeCString(notesManifestJSON)
  }

  api.invoke = { ctxPtr, typePtr, idPtr, payloadPtr in
    guard let ctxPtr = ctxPtr,
      let typePtr = typePtr,
      let idPtr = idPtr,
      let payloadPtr = payloadPtr
    else { return nil }

    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let type = String(cString: typePtr)
    let id = String(cString: idPtr)
    let payload = String(cString: payloadPtr)

    if type == "tool", let tool = ctx.tools[id] {
      let result = tool.run(args: payload)
      return makeCString(result)
    }

    return makeCString(
      Envelope.failure(.notFound, "Unknown capability or tool: \(type)/\(id)"))
  }

  return api
}()

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  return UnsafeRawPointer(&api)
}
