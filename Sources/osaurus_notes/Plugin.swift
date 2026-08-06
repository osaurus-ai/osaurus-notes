import Foundation
import OsaurusPluginABI
import OsaurusPluginKit

// MARK: - Result models

struct NoteSummary: Codable, Equatable {
  let id: String
  let title: String
  let preview: String
  let previewTruncated: Bool
  let folder: String
  let createdAt: String?
  let modifiedAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case preview
    case previewTruncated = "preview_truncated"
    case folder
    case createdAt = "created_at"
    case modifiedAt = "modified_at"
  }
}

struct QueryNotesResult: Codable, Equatable {
  let notes: [NoteSummary]
  let returned: Int
  let total: Int
  let truncated: Bool
  let nextCursor: String?
  let partialFailureCount: Int

  enum CodingKeys: String, CodingKey {
    case notes
    case returned
    case total
    case truncated
    case nextCursor = "next_cursor"
    case partialFailureCount = "partial_failure_count"
  }
}

struct NoteDetail: Codable, Equatable {
  let id: String
  let title: String
  let body: String
  let folder: String
  let createdAt: String?
  let modifiedAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case body
    case folder
    case createdAt = "created_at"
    case modifiedAt = "modified_at"
  }
}

struct CreateNoteResult: Codable, Equatable {
  let id: String
  let folder: String
}

// MARK: - AppleScript execution

enum AppleScriptExecutor {
  static let timeoutSeconds: TimeInterval = 30
  static let maximumOutputBytes = 16 * 1024 * 1024

  static func runScript(_ source: String, tool: String) throws -> String {
    let output: ProcessRunner.Output
    do {
      output = try ProcessRunner.run(
        executable: "/usr/bin/osascript",
        arguments: ["-e", source],
        timeout: timeoutSeconds,
        maxOutputBytes: maximumOutputBytes
      )
    } catch {
      throw EnvelopeFailure(
        .unavailable,
        "Failed to start AppleScript: \(error.localizedDescription)",
        retryable: false,
        tool: tool
      )
    }

    if output.timedOut {
      throw EnvelopeFailure(
        .timeout,
        "Apple Notes did not respond within \(Int(timeoutSeconds)) seconds",
        tool: tool
      )
    }

    if output.exitStatus != 0 {
      let stderr = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
      let lower = stderr.lowercased()
      if lower.contains("not allowed") || lower.contains("not authorized")
        || lower.contains("permission") || lower.contains("-1743")
      {
        throw EnvelopeFailure(
          .userDenied,
          "Automation permission for Notes was denied. Grant access in System Settings → Privacy & Security → Automation.",
          tool: tool
        )
      }
      if lower.contains("isn't running") || lower.contains("is not running")
        || lower.contains("connection is invalid") || lower.contains("can't get application")
      {
        throw EnvelopeFailure(
          .unavailable,
          "Apple Notes is unavailable: \(stderr.isEmpty ? "unknown error" : stderr)",
          tool: tool
        )
      }
      throw EnvelopeFailure(
        .executionError,
        "AppleScript failed while using Notes: \(stderr.isEmpty ? "unknown error" : stderr)",
        tool: tool
      )
    }

    return output.stdoutText.trimmingCharacters(in: .newlines)
  }

  static func escapeForAppleScript(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}

// MARK: - Tool protocol

protocol Tool {
  var id: String { get }
  var description: String { get }
  var parameters: String { get }
  var requirements: [String] { get }
  func run(args: String) -> String
}

extension Tool {
  var requirements: [String] { ["automation"] }

  func handlingFailures(_ operation: () throws -> String) -> String {
    do {
      return try operation()
    } catch let failure as EnvelopeFailure {
      return renderFailure(failure, tool: id)
    } catch {
      return Envelope.failure(
        .executionError,
        "Unexpected \(id) failure: \(error.localizedDescription)",
        tool: id
      )
    }
  }
}

// MARK: - query_notes

struct QueryNotesTool: Tool {
  let id = "query_notes"
  let description =
    "Browse or search Apple Notes with optional exact-folder filtering and cursor pagination. Returns metadata and previews; use get_note for full bodies."
  let parameters = NotesContract.queryNotesParameters

  func run(args: String) -> String {
    handlingFailures {
      let input = try NotesArguments.object(
        args,
        allowed: ["query", "folder", "limit", "cursor"]
      )
      let query = try NotesArguments.optionalString(
        input,
        "query",
        maximumLength: NotesContract.maximumQueryLength
      )
      let folder = try NotesArguments.optionalString(
        input,
        "folder",
        maximumLength: NotesContract.maximumFolderLength
      )
      let limit = try NotesArguments.limit(input)
      let offset = try NotesArguments.cursorOffset(input)

      let escapedQuery = AppleScriptExecutor.escapeForAppleScript(query ?? "")
      let escapedFolder = AppleScriptExecutor.escapeForAppleScript(folder ?? "")
      let hasQuery = query == nil ? "false" : "true"
      let hasFolder = folder == nil ? "false" : "true"

      let script = """
        tell application "Notes"
            set queryText to "\(escapedQuery)"
            set requestedFolder to "\(escapedFolder)"
            set allNotes to notes

            if \(hasFolder) then
                set targetFolder to missing value
                repeat with currentFolder in folders
                    if (name of currentFolder as text) is requestedFolder then
                        set targetFolder to currentFolder
                        exit repeat
                    end if
                end repeat
                if targetFolder is missing value then return "NOT_FOUND"
                set allNotes to notes of targetFolder
            end if

            set output to ""
            set failureCount to 0
            set totalCount to 0
            set returnedCount to 0

            repeat with currentNote in allNotes
                try
                    set noteTitle to name of currentNote as text
                    set noteBody to plaintext of currentNote as text
                    set matchesQuery to true
                    if \(hasQuery) then
                        set matchesQuery to (noteTitle contains queryText) or (noteBody contains queryText)
                    end if

                    if matchesQuery then
                        set currentIndex to totalCount
                        set totalCount to totalCount + 1

                        if currentIndex ≥ \(offset) and returnedCount < \(limit) then
                            set noteID to id of currentNote as text
                            set folderName to name of container of currentNote as text
                            set createdDate to creation date of currentNote
                            set modifiedDate to modification date of currentNote
                            set wasTruncated to false
                            set notePreview to noteBody
                            if (length of notePreview) > \(NotesContract.previewLength) then
                                set notePreview to (characters 1 thru \(NotesContract.previewLength) of notePreview) as text
                                set wasTruncated to true
                            end if

                            set output to output & my encodeField(noteID) & tab & my encodeField(noteTitle) & tab & my encodeField(notePreview) & tab & my encodeField(folderName) & tab & (createdDate as «class isot» as string) & tab & (modifiedDate as «class isot» as string) & tab & (wasTruncated as text) & linefeed
                            set returnedCount to returnedCount + 1
                        end if
                    end if
                on error
                    set failureCount to failureCount + 1
                end try
            end repeat

            return "OK" & tab & (failureCount as text) & tab & (totalCount as text) & linefeed & output
        end tell
        \(appleScriptFieldEncoderHandlers)
        """

      let output = try AppleScriptExecutor.runScript(script, tool: id)
      if output == "NOT_FOUND" {
        throw EnvelopeFailure(
          .notFound,
          "Notes folder not found: \(folder ?? "")",
          field: "folder",
          expected: "an existing Notes folder",
          tool: id
        )
      }
      let result = try parseQueryNotesOutput(output, offset: offset)
      return successEnvelope(result, tool: id)
    }
  }
}

func parseQueryNotesOutput(_ output: String, offset: Int) throws -> QueryNotesResult {
  let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  guard let header = lines.first else {
    throw EnvelopeFailure(.executionError, "query_notes returned no data")
  }
  let headerFields = header.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
  guard headerFields.count == 3,
    headerFields[0] == "OK",
    let partialFailureCount = Int(headerFields[1]),
    let total = Int(headerFields[2])
  else {
    throw EnvelopeFailure(.executionError, "query_notes returned an invalid response")
  }

  var notes: [NoteSummary] = []
  for line in lines.dropFirst() where !line.isEmpty {
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard fields.count == 7 else {
      throw EnvelopeFailure(.executionError, "query_notes returned a malformed note")
    }
    notes.append(
      NoteSummary(
        id: decodeAppleScriptField(fields[0]),
        title: decodeAppleScriptField(fields[1]),
        preview: decodeAppleScriptField(fields[2]),
        previewTruncated: fields[6] == "true",
        folder: decodeAppleScriptField(fields[3]),
        createdAt: fields[4].isEmpty ? nil : fields[4],
        modifiedAt: fields[5].isEmpty ? nil : fields[5]
      )
    )
  }

  let nextOffset = offset + notes.count
  let truncated = nextOffset < total
  return QueryNotesResult(
    notes: notes,
    returned: notes.count,
    total: total,
    truncated: truncated,
    nextCursor: truncated ? String(nextOffset) : nil,
    partialFailureCount: partialFailureCount
  )
}

// MARK: - get_note

struct GetNoteTool: Tool {
  let id = "get_note"
  let description = "Read a complete Apple Note by its stable ID."
  let parameters = NotesContract.getNoteParameters

  func run(args: String) -> String {
    handlingFailures {
      let input = try NotesArguments.object(args, allowed: ["id"])
      let noteID = try NotesArguments.requiredString(input, "id", maximumLength: 2048)
      let escapedID = AppleScriptExecutor.escapeForAppleScript(noteID)

      let script = """
        tell application "Notes"
            set matchingNote to missing value
            repeat with currentNote in notes
                try
                    if (id of currentNote as text) is "\(escapedID)" then
                        set matchingNote to currentNote
                        exit repeat
                    end if
                end try
            end repeat
            if matchingNote is missing value then return "NOT_FOUND"

            set noteID to id of matchingNote as text
            set noteTitle to name of matchingNote as text
            set noteBody to plaintext of matchingNote as text
            set folderName to name of container of matchingNote as text
            set createdDate to creation date of matchingNote
            set modifiedDate to modification date of matchingNote
            return "OK" & tab & my encodeField(noteID) & tab & my encodeField(noteTitle) & tab & my encodeField(noteBody) & tab & my encodeField(folderName) & tab & (createdDate as «class isot» as string) & tab & (modifiedDate as «class isot» as string)
        end tell
        \(appleScriptFieldEncoderHandlers)
        """

      let output = try AppleScriptExecutor.runScript(script, tool: id)
      if output == "NOT_FOUND" {
        throw EnvelopeFailure(
          .notFound,
          "Note not found",
          field: "id",
          expected: "an existing Apple Notes ID",
          tool: id
        )
      }
      let result = try parseGetNoteOutput(output)
      return successEnvelope(result, tool: id)
    }
  }
}

func parseGetNoteOutput(_ output: String) throws -> NoteDetail {
  let fields = output.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
  guard fields.count == 7, fields[0] == "OK" else {
    throw EnvelopeFailure(.executionError, "get_note returned an invalid response")
  }
  return NoteDetail(
    id: decodeAppleScriptField(fields[1]),
    title: decodeAppleScriptField(fields[2]),
    body: decodeAppleScriptField(fields[3]),
    folder: decodeAppleScriptField(fields[4]),
    createdAt: fields[5].isEmpty ? nil : fields[5],
    modifiedAt: fields[6].isEmpty ? nil : fields[6]
  )
}

// MARK: - create_note

struct CreateNoteTool: Tool {
  let id = "create_note"
  let description =
    "Create an Apple Note, optionally in an existing exact-name folder. Returns the stable note ID and actual destination folder."
  let parameters = NotesContract.createNoteParameters

  func run(args: String) -> String {
    handlingFailures {
      let input = try NotesArguments.object(args, allowed: ["title", "body", "folder"])
      let title = try NotesArguments.requiredString(
        input,
        "title",
        maximumLength: NotesContract.maximumTitleLength
      )
      let body = try NotesArguments.requiredString(
        input,
        "body",
        maximumLength: NotesContract.maximumBodyLength,
        allowEmpty: true
      )
      let folder = try NotesArguments.optionalString(
        input,
        "folder",
        maximumLength: NotesContract.maximumFolderLength
      )

      let temporaryFile = FileManager.default.temporaryDirectory.appendingPathComponent(
        "osaurus-note-\(UUID().uuidString).txt"
      )
      do {
        try body.write(to: temporaryFile, atomically: true, encoding: .utf8)
      } catch {
        throw EnvelopeFailure(
          .executionError,
          "Failed to prepare note body: \(error.localizedDescription)",
          retryable: false,
          tool: id
        )
      }
      defer { try? FileManager.default.removeItem(at: temporaryFile) }

      let escapedTitle = AppleScriptExecutor.escapeForAppleScript(title)
      let escapedFolder = AppleScriptExecutor.escapeForAppleScript(folder ?? "")
      let escapedPath = AppleScriptExecutor.escapeForAppleScript(temporaryFile.path)
      let hasFolder = folder == nil ? "false" : "true"

      let script = """
        tell application "Notes"
            set requestedFolder to "\(escapedFolder)"
            set targetFolder to missing value

            if \(hasFolder) then
                repeat with currentFolder in folders
                    if (name of currentFolder as text) is requestedFolder then
                        set targetFolder to currentFolder
                        exit repeat
                    end if
                end repeat
                if targetFolder is missing value then return "NOT_FOUND"
            end if

            set noteBody to read file POSIX file "\(escapedPath)" as «class utf8»
            if \(hasFolder) then
                set createdNote to make new note at targetFolder with properties {name:"\(escapedTitle)", body:noteBody}
            else
                set createdNote to make new note with properties {name:"\(escapedTitle)", body:noteBody}
            end if

            set noteID to id of createdNote as text
            set actualFolder to name of container of createdNote as text
            return "OK" & tab & my encodeField(noteID) & tab & my encodeField(actualFolder)
        end tell
        \(appleScriptFieldEncoderHandlers)
        """

      let output = try AppleScriptExecutor.runScript(script, tool: id)
      if output == "NOT_FOUND" {
        throw EnvelopeFailure(
          .notFound,
          "Notes folder not found: \(folder ?? "")",
          field: "folder",
          expected: "an existing Notes folder",
          tool: id
        )
      }
      let result = try parseCreateNoteOutput(output)
      return successEnvelope(result, tool: id)
    }
  }
}

func parseCreateNoteOutput(_ output: String) throws -> CreateNoteResult {
  let fields = output.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
  guard fields.count == 3, fields[0] == "OK" else {
    throw EnvelopeFailure(.executionError, "create_note returned an invalid response")
  }
  return CreateNoteResult(
    id: decodeAppleScriptField(fields[1]),
    folder: decodeAppleScriptField(fields[2])
  )
}

// MARK: - Manifest

let notesTools: [Tool] = [
  QueryNotesTool(),
  GetNoteTool(),
  CreateNoteTool(),
]

func buildNotesManifestJSON(tools: [Tool] = notesTools) -> String {
  let toolsJSON = tools.map { tool in
    let requirementsJSON =
      "[" + tool.requirements.map { "\"\(Envelope.escape($0))\"" }.joined(separator: ",") + "]"
    return """
      {
        "id": "\(Envelope.escape(tool.id))",
        "description": "\(Envelope.escape(tool.description))",
        "parameters": \(tool.parameters),
        "requirements": \(requirementsJSON),
        "permission_policy": "ask"
      }
      """
  }.joined(separator: ",")

  return """
    {
      "plugin_id": "osaurus.notes",
      "name": "Apple Notes",
      "version": "\(NotesContract.version)",
      "description": "Browse, read, and create Apple Notes by stable identifier.",
      "license": "MIT",
      "authors": ["Dinoki Labs"],
      "min_macos": "13.0",
      "min_osaurus": "0.5.0",
      "capabilities": {
        "tools": [\(toolsJSON)]
      }
    }
    """
}

let notesManifestJSON = buildNotesManifestJSON()

// MARK: - C ABI

private final class PluginContext {
  let tools: [String: Tool]

  init() {
    tools = Dictionary(uniqueKeysWithValues: notesTools.map { ($0.id, $0) })
  }
}

private var pluginAPI = PluginEntry.makeAPI(
  version: OsrABIVersion.v2,
  init: {
    Unmanaged.passRetained(PluginContext()).toOpaque()
  },
  destroy: { pointer in
    guard let pointer else { return }
    Unmanaged<PluginContext>.fromOpaque(pointer).release()
  },
  getManifest: { pointer in
    guard pointer != nil else { return nil }
    return osrMakeCString(notesManifestJSON)
  },
  invoke: { contextPointer, typePointer, idPointer, payloadPointer in
    guard let contextPointer, let typePointer, let idPointer, let payloadPointer else {
      return nil
    }

    let context = Unmanaged<PluginContext>.fromOpaque(contextPointer).takeUnretainedValue()
    let type = String(cString: typePointer)
    let id = String(cString: idPointer)
    let payload = String(cString: payloadPointer)

    guard type == "tool", let tool = context.tools[id] else {
      return osrMakeCString(
        Envelope.failure(
          .toolNotFound,
          "Unknown capability or tool: \(type)/\(id)",
          tool: id
        )
      )
    }
    return osrMakeCString(tool.run(args: payload))
  }
)

@_cdecl("osaurus_plugin_entry_v2")
public func osaurus_plugin_entry_v2(_ host: UnsafeRawPointer?) -> UnsafeRawPointer? {
  PluginEntry.enterV2(host, api: &pluginAPI)
}

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  PluginEntry.enterV1(api: &pluginAPI)
}
