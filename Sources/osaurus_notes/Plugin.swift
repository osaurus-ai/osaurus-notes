import Foundation

// MARK: - Models

struct Note: Codable {
  let name: String
  let content: String
  let creationDate: Date?
  let modificationDate: Date?
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
  static func run(_ source: String) -> NSAppleEventDescriptor? {
    var error: NSDictionary?
    if let scriptObject = NSAppleScript(source: source) {
      let result = scriptObject.executeAndReturnError(&error)
      if let error = error {
        print("AppleScript Error: \(error)")
        return nil
      }
      return result
    }
    return nil
  }

  static func runAndGetString(_ source: String) -> String? {
    return run(source)?.stringValue
  }

  // Helper to extract list of notes from NSAppleEventDescriptor
  // static func parseNotesList(_ descriptor: NSAppleEventDescriptor) -> [Note] { ... } - REMOVED unused

}

// MARK: - Tools

protocol Tool {
  var id: String { get }
  var description: String { get }
  var parameters: String { get }
  var requirements: [String] { get }
  func run(args: String) -> String
}

// Tool Definitions

struct ListNotesTool: Tool {
  let id = "list_notes"
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
    let limit = (try? JSONDecoder().decode(Args.self, from: Data(args.utf8)))?.limit ?? 50
    let maxPreview = 200

    // Modified script to return list of lists for easier parsing: {{name, content}, ...}
    let script = """
      tell application "Notes"
          set notesList to {}
          set noteCount to 0
          
          set allNotes to notes
          
          repeat with i from 1 to (count of allNotes)
              if noteCount >= \(limit) then exit repeat
              
              try
                  set currentNote to item i of allNotes
                  set noteName to name of currentNote
                  set noteContent to plaintext of currentNote
                  
                  if (length of noteContent) > \(maxPreview) then
                      set noteContent to (characters 1 thru \(maxPreview) of noteContent) as string
                      set noteContent to noteContent & "..."
                  end if
                  
                  set end of notesList to {noteName, noteContent}
                  set noteCount to noteCount + 1
              on error
              end try
          end repeat
          
          return notesList
      end tell
      """

    guard let result = AppleScriptExecutor.run(script) else {
      return "{\"error\": \"Failed to execute AppleScript\"}"
    }

    var notes: [Note] = []
    let numItems = result.numberOfItems

    for i in 1...numItems {
      if let noteData = result.atIndex(i), noteData.numberOfItems >= 2 {
        let name = noteData.atIndex(1)?.stringValue ?? "Untitled"
        let content = noteData.atIndex(2)?.stringValue ?? ""
        notes.append(Note(name: name, content: content, creationDate: nil, modificationDate: nil))
      }
    }

    guard let json = try? JSONEncoder().encode(notes),
      let jsonString = String(data: json, encoding: .utf8)
    else {
      return "[]"
    }
    return jsonString
  }
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
      return "{\"error\": \"Invalid arguments\"}"
    }

    let searchTerm = input.query.lowercased().replacingOccurrences(of: "\"", with: "\\\"")
    let maxNotes = 50
    let maxPreview = 200

    let script = """
      tell application "Notes"
          set matchedNotes to {}
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
                      if (length of noteContent) > \(maxPreview) then
                          set noteContent to (characters 1 thru \(maxPreview) of noteContent) as string
                          set noteContent to noteContent & "..."
                      end if
                      
                      set end of matchedNotes to {noteName, noteContent}
                      set noteCount to noteCount + 1
                  end if
              on error
              end try
          end repeat
          
          return matchedNotes
      end tell
      """

    guard let result = AppleScriptExecutor.run(script) else {
      return "[]"
    }

    var notes: [Note] = []
    let numItems = result.numberOfItems
    for i in 1...numItems {
      if let noteData = result.atIndex(i), noteData.numberOfItems >= 2 {
        let name = noteData.atIndex(1)?.stringValue ?? "Untitled"
        let content = noteData.atIndex(2)?.stringValue ?? ""
        notes.append(Note(name: name, content: content, creationDate: nil, modificationDate: nil))
      }
    }

    guard let json = try? JSONEncoder().encode(notes),
      let jsonString = String(data: json, encoding: .utf8)
    else {
      return "[]"
    }
    return jsonString
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
      return "{\"success\": false, \"message\": \"Invalid arguments\"}"
    }

    let title = input.title
    let body = input.body
    let folderName = input.folder ?? "Claude"

    // Use temp file for body content to handle special characters correctly
    let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent(
      "note-content-\(UUID().uuidString).txt")
    do {
      try body.write(to: tmpFile, atomically: true, encoding: .utf8)
    } catch {
      return "{\"success\": false, \"message\": \"Failed to write temporary file\"}"
    }

    defer {
      try? FileManager.default.removeItem(at: tmpFile)
    }

    let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
    let escapedFolder = folderName.replacingOccurrences(of: "\"", with: "\\\"")
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
              return "SUCCESS:" & actualFolderName & ":false"
          else
              make new note with properties {name:"\(escapedTitle)", body:noteContent}
              return "SUCCESS:Notes:true"
          end if
      end tell
      """

    guard let result = AppleScriptExecutor.runAndGetString(script) else {
      return "{\"success\": false, \"message\": \"AppleScript execution failed\"}"
    }

    if result.hasPrefix("SUCCESS:") {
      let parts = result.components(separatedBy: ":")
      let actualFolder = parts.count > 1 ? parts[1] : "Notes"
      let usedDefault = parts.count > 2 ? (parts[2] == "true") : false

      let resultObj = CreateNoteResult(
        success: true,
        note: Note(name: title, content: body, creationDate: nil, modificationDate: nil),
        message: nil,
        folderName: actualFolder,
        usedDefaultFolder: usedDefault
      )

      if let json = try? JSONEncoder().encode(resultObj),
        let jsonStr = String(data: json, encoding: .utf8)
      {
        return jsonStr
      }
    }

    return "{\"success\": false, \"message\": \"Failed to parse result: \(result)\"}"
  }
}

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
    let toolsList: [Tool] = [
      ListNotesTool(),
      SearchNotesTool(),
      CreateNoteTool(),
    ]
    var dict: [String: Tool] = [:]
    for t in toolsList {
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
    guard let ctxPtr = ctxPtr else { return nil }
    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()

    // Build tools JSON
    let toolsJson = ctx.tools.values.map { tool -> String in
      let requirementsJson =
        "[" + tool.requirements.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
      return """
        {
            "id": "\(tool.id)",
            "description": "\(tool.description)",
            "parameters": \(tool.parameters),
            "requirements": \(requirementsJson),
            "permission_policy": "ask"
        }
        """
    }.joined(separator: ",")

    let manifest = """
      {
        "plugin_id": "osaurus.notes",
        "name": "Apple Notes",
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
    return makeCString(manifest)
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

    return makeCString("{\"error\": \"Unknown capability or tool\"}")
  }

  return api
}()

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  return UnsafeRawPointer(&api)
}
