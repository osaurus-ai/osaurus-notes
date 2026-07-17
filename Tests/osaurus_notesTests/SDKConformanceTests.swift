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
      osaurus_plugin_entry_v2(nil), manifestJSON: notesManifestJSON)
  }

  func testV1EntryPointReturnsConformantPluginAPI() throws {
    try ABIConformance.assertEntryConformance(
      osaurus_plugin_entry(), manifestJSON: notesManifestJSON)
  }

  func testInvalidArgsFailureIsCanonical() throws {
    let json = ListNotesTool().run(args: "not json at all")
    try assertCanonicalFailure(json, kind: .invalidArgs)
  }
}
