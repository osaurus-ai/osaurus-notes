import Foundation
import OsaurusPluginKit

enum NotesContract {
  static let version = "2.0.0"
  static let defaultLimit = 50
  static let maximumLimit = 100
  static let previewLength = 200
  static let maximumQueryLength = 500
  static let maximumFolderLength = 255
  static let maximumTitleLength = 500
  static let maximumBodyLength = 1_000_000

  static let queryNotesParameters = """
    {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "Optional case-insensitive text matched against note titles and bodies.",
          "minLength": 1,
          "maxLength": \(maximumQueryLength)
        },
        "folder": {
          "type": "string",
          "description": "Optional exact Notes folder name. A missing explicit folder returns not_found.",
          "minLength": 1,
          "maxLength": \(maximumFolderLength)
        },
        "limit": {
          "type": "integer",
          "description": "Maximum notes returned per page.",
          "default": \(defaultLimit),
          "minimum": 1,
          "maximum": \(maximumLimit)
        },
        "cursor": {
          "type": "string",
          "description": "Pagination cursor returned by a previous query_notes call.",
          "pattern": "^[0-9]+$",
          "maxLength": 20
        }
      },
      "required": [],
      "additionalProperties": false
    }
    """

  static let getNoteParameters = """
    {
      "type": "object",
      "properties": {
        "id": {
          "type": "string",
          "description": "Stable Apple Notes identifier returned by query_notes or create_note.",
          "minLength": 1,
          "maxLength": 2048
        }
      },
      "required": ["id"],
      "additionalProperties": false
    }
    """

  static let createNoteParameters = """
    {
      "type": "object",
      "properties": {
        "title": {
          "type": "string",
          "description": "Note title.",
          "minLength": 1,
          "maxLength": \(maximumTitleLength)
        },
        "body": {
          "type": "string",
          "description": "Full note body.",
          "maxLength": \(maximumBodyLength)
        },
        "folder": {
          "type": "string",
          "description": "Optional exact Notes folder name. Omit to use Notes' default destination.",
          "minLength": 1,
          "maxLength": \(maximumFolderLength)
        }
      },
      "required": ["title", "body"],
      "additionalProperties": false
    }
    """
}

enum NotesArguments {
  static func object(_ payload: String, allowed: Set<String>) throws -> [String: Any] {
    let args = try ArgValidation.parseObject(payload)
    if let unknown = args.keys.first(where: { !allowed.contains($0) }) {
      throw EnvelopeFailure(
        .invalidArgs,
        "Unknown argument: \(unknown)",
        field: unknown,
        expected: "one of: \(allowed.sorted().joined(separator: ", "))"
      )
    }
    return args
  }

  static func requiredString(
    _ args: [String: Any],
    _ field: String,
    maximumLength: Int,
    allowEmpty: Bool = false
  ) throws -> String {
    guard let raw = args[field] else {
      throw EnvelopeFailure(
        .invalidArgs,
        "Missing required argument: \(field)",
        field: field,
        expected: "string"
      )
    }
    guard let value = raw as? String else {
      throw EnvelopeFailure(
        .invalidArgs,
        "Argument '\(field)' must be a string",
        field: field,
        expected: "string"
      )
    }
    if !allowEmpty && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw EnvelopeFailure(
        .invalidArgs,
        "Argument '\(field)' must not be empty",
        field: field,
        expected: "non-empty string"
      )
    }
    guard value.count <= maximumLength else {
      throw EnvelopeFailure(
        .invalidArgs,
        "Argument '\(field)' exceeds the maximum length of \(maximumLength)",
        field: field,
        expected: "string of at most \(maximumLength) characters"
      )
    }
    return value
  }

  static func optionalString(
    _ args: [String: Any],
    _ field: String,
    maximumLength: Int
  ) throws -> String? {
    guard let raw = args[field] else { return nil }
    guard let value = raw as? String else {
      throw EnvelopeFailure(
        .invalidArgs,
        "Argument '\(field)' must be a string",
        field: field,
        expected: "string"
      )
    }
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw EnvelopeFailure(
        .invalidArgs,
        "Argument '\(field)' must not be empty",
        field: field,
        expected: "non-empty string"
      )
    }
    guard value.count <= maximumLength else {
      throw EnvelopeFailure(
        .invalidArgs,
        "Argument '\(field)' exceeds the maximum length of \(maximumLength)",
        field: field,
        expected: "string of at most \(maximumLength) characters"
      )
    }
    return value
  }

  static func limit(_ args: [String: Any]) throws -> Int {
    guard let value = args["limit"] else { return NotesContract.defaultLimit }
    if value is Bool {
      throw EnvelopeFailure(
        .invalidArgs,
        "Argument 'limit' must be an integer",
        field: "limit",
        expected: "integer from 1 through \(NotesContract.maximumLimit)"
      )
    }
    let resolved: Int
    if let integer = value as? Int {
      resolved = integer
    } else if let number = value as? Double,
      number.rounded() == number,
      let integer = Int(exactly: number)
    {
      resolved = integer
    } else {
      throw EnvelopeFailure(
        .invalidArgs,
        "Argument 'limit' must be an integer",
        field: "limit",
        expected: "integer from 1 through \(NotesContract.maximumLimit)"
      )
    }
    guard (1...NotesContract.maximumLimit).contains(resolved) else {
      throw EnvelopeFailure(
        .invalidArgs,
        "Argument 'limit' must be between 1 and \(NotesContract.maximumLimit)",
        field: "limit",
        expected: "integer from 1 through \(NotesContract.maximumLimit)"
      )
    }
    return resolved
  }

  static func cursorOffset(_ args: [String: Any]) throws -> Int {
    guard let raw = args["cursor"] else { return 0 }
    guard let cursor = raw as? String,
      !cursor.isEmpty,
      cursor.count <= 20,
      cursor.allSatisfy(\.isNumber),
      let offset = Int(cursor),
      offset >= 0
    else {
      throw EnvelopeFailure(
        .invalidArgs,
        "Argument 'cursor' is not a valid query_notes cursor",
        field: "cursor",
        expected: "cursor returned by query_notes"
      )
    }
    return offset
  }
}

func renderFailure(_ failure: EnvelopeFailure, tool: String) -> String {
  Envelope.failure(
    failure.kind,
    failure.message,
    retryable: failure.retryable,
    field: failure.field,
    expected: failure.expected,
    tool: failure.tool ?? tool,
    dataJSON: failure.dataJSON
  )
}

func successEnvelope<T: Encodable>(_ result: T, tool: String) -> String {
  do {
    let data = try JSONEncoder().encode(result)
    guard let json = String(data: data, encoding: .utf8) else {
      return Envelope.failure(
        .executionError,
        "Failed to encode \(tool) result",
        retryable: false,
        tool: tool
      )
    }
    return Envelope.success(tool: tool, rawResult: json)
  } catch {
    return Envelope.failure(
      .executionError,
      "Failed to encode \(tool) result: \(error.localizedDescription)",
      retryable: false,
      tool: tool
    )
  }
}
