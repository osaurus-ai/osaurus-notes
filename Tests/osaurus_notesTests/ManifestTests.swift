import Foundation
import Testing

@testable import osaurus_notes

@Suite("Plugin Manifest")
struct ManifestTests {

  private enum ManifestError: Error {
    case entryPointFailed
    case nilManifest
    case invalidJSON
  }

  private func loadManifest() throws -> [String: Any] {
    guard let apiPtr = osaurus_plugin_entry() else {
      throw ManifestError.entryPointFailed
    }

    let fnPtrSize = MemoryLayout<UnsafeRawPointer?>.stride
    let initPtr = apiPtr.load(
      fromByteOffset: fnPtrSize,
      as: (@convention(c) () -> UnsafeMutableRawPointer?).self)
    let ctx = initPtr()

    let getManifestPtr = apiPtr.load(
      fromByteOffset: fnPtrSize * 3,
      as: (@convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?).self)
    guard let cStr = getManifestPtr(ctx) else {
      throw ManifestError.nilManifest
    }
    let jsonString = String(cString: cStr)

    let freeStringPtr = apiPtr.load(
      fromByteOffset: 0,
      as: (@convention(c) (UnsafePointer<CChar>?) -> Void).self)
    freeStringPtr(cStr)

    let destroyPtr = apiPtr.load(
      fromByteOffset: fnPtrSize * 2,
      as: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
    destroyPtr(ctx)

    guard let data = jsonString.data(using: .utf8),
      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw ManifestError.invalidJSON
    }
    return manifest
  }

  private func toolMap(from manifest: [String: Any]) -> [String: [String: Any]] {
    let capabilities = manifest["capabilities"] as? [String: Any]
    let tools = capabilities?["tools"] as? [[String: Any]] ?? []
    return Dictionary(
      uniqueKeysWithValues: tools.compactMap { tool -> (String, [String: Any])? in
        guard let id = tool["id"] as? String else { return nil }
        return (id, tool)
      })
  }

  @Test("manifest has correct plugin identity")
  func pluginIdentity() throws {
    let manifest = try loadManifest()
    #expect(manifest["plugin_id"] as? String == "osaurus.notes")
  }

  @Test("manifest declares expected notes tools")
  func toolIDs() throws {
    let map = try toolMap(from: loadManifest())
    #expect(Set(map.keys) == ["list_notes", "search_notes", "create_note"])
  }

  @Test("all notes tools declare notes requirement and approval")
  func requirementsAndPermissions() throws {
    let map = try toolMap(from: loadManifest())
    for (id, tool) in map {
      #expect(tool["requirements"] as? [String] == ["notes"])
      #expect(tool["permission_policy"] as? String == "ask", "Tool '\(id)' should ask")
    }
  }

  @Test("search and create tools declare required parameters")
  func requiredParameters() throws {
    let map = try toolMap(from: loadManifest())

    let searchParams = map["search_notes"]?["parameters"] as? [String: Any]
    let searchProperties = searchParams?["properties"] as? [String: Any]
    let searchRequired = searchParams?["required"] as? [String] ?? []
    #expect(searchRequired.contains("query"))
    #expect(searchProperties?["limit"] != nil)

    let createParams = map["create_note"]?["parameters"] as? [String: Any]
    let createRequired = Set(createParams?["required"] as? [String] ?? [])
    #expect(createRequired == ["title", "body"])
  }
}
