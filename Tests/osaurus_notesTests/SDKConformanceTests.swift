import OsaurusPluginKit
import OsaurusPluginTestSupport
import XCTest

@testable import osaurus_notes

final class SDKConformanceTests: XCTestCase {
  func testManifestPassesSDKRegistryConformance() throws {
    try ManifestConformance.assertConformant(notesManifestJSON)
  }

  func testV2EntryPointReturnsConformantPluginAPI() throws {
    try ABIConformance.assertEntryConformance(
      osaurus_plugin_entry_v2(nil),
      manifestJSON: notesManifestJSON
    )
  }

  func testV1EntryPointReturnsConformantPluginAPI() throws {
    try ABIConformance.assertEntryConformance(
      osaurus_plugin_entry(),
      manifestJSON: notesManifestJSON
    )
  }

  func testInvalidArgumentsUseCanonicalFailure() throws {
    let json = QueryNotesTool().run(args: #"{"limit":0}"#)
    try assertCanonicalFailure(json, kind: .invalidArgs)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    )
    XCTAssertEqual(object["tool"] as? String, "query_notes")
  }
}
