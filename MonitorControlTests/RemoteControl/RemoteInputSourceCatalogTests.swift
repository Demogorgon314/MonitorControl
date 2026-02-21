import XCTest
@testable import RemoteControlCore

final class RemoteInputSourceCatalogTests: XCTestCase {
  func testCodeResolutionSupportsCanonicalNamesAndAliases() {
    XCTAssertEqual(RemoteInputSourceCatalog.code(forName: "HDMI-1"), 17)
    XCTAssertEqual(RemoteInputSourceCatalog.code(forName: "hdmi"), 17)
    XCTAssertEqual(RemoteInputSourceCatalog.code(forName: "dp"), 15)
    XCTAssertEqual(RemoteInputSourceCatalog.code(forName: "DisplayPort2"), 16)
    XCTAssertEqual(RemoteInputSourceCatalog.code(forName: " vga-2 "), 2)
  }

  func testCodeResolutionRejectsUnknownName() {
    XCTAssertNil(RemoteInputSourceCatalog.code(forName: "thunderbolt-1"))
    XCTAssertNil(RemoteInputSourceCatalog.code(forName: ""))
  }

  func testSourceLookupReturnsFallbackForUnknownCode() {
    let known = RemoteInputSourceCatalog.source(for: 17)
    XCTAssertEqual(known.code, 17)
    XCTAssertEqual(known.name, "HDMI-1")

    let unknown = RemoteInputSourceCatalog.source(for: 99)
    XCTAssertEqual(unknown.code, 99)
    XCTAssertEqual(unknown.name, "UNKNOWN-99")
  }
}
