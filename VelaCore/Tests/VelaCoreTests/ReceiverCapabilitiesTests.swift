import XCTest
@testable import VelaCore

final class ReceiverCapabilitiesTests: XCTestCase {
    private func plist(_ object: Any, format: PropertyListSerialization.PropertyListFormat = .binary) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0)
    }

    func testObservedDisplayInSyntheticPlist() throws {
        // Shape and display values observed in the supplied receiver plist; identifiers omitted.
        let body = try plist(["displays": [["widthPixels": 1024, "heightPixels": 600, "maxFPS": 30, "features": 10]]])
        let displays = try XCTUnwrap(ReceiverCapabilities.displays(from: body))
        XCTAssertEqual(displays.count, 1)
        XCTAssertEqual(displays[0].width, 1024)
        XCTAssertEqual(displays[0].height, 600)
        XCTAssertEqual(displays[0].maxFPS, 30)
    }
    func testXMLAndUntrustedValues() throws {
        let xml = try plist(["displays": [["widthPixels": true, "heightPixels": 600], ["widthPixels": 100, "heightPixels": 80, "maxFPS": 999]]], format: .xml)
        let displays = try XCTUnwrap(ReceiverCapabilities.displays(from: xml))
        XCTAssertEqual(displays.count, 1)
        XCTAssertNil(displays[0].maxFPS)
        XCTAssertNil(ReceiverCapabilities.displays(from: Data("not a plist".utf8)))
        XCTAssertNil(ReceiverCapabilities.displays(from: try plist(["displays": Array(repeating: 0, count: 17)])))
        XCTAssertNil(ReceiverCapabilities.displays(from: Data(repeating: 0, count: ReceiverProbe.maximumResponseBytes + 1)))
    }
}
