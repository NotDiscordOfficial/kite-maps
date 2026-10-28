#if canImport(VideoToolbox) && canImport(CoreGraphics)
import XCTest
@testable import VelaCore

final class H264TestPatternTests: XCTestCase {
    func testSingleFrameHasCodecConfiguration() throws {
        let result = try H264TestPattern.encode()
        XCTAssertGreaterThan(result.avcc.count, 4)
        XCTAssertFalse(result.sps.isEmpty)
        XCTAssertFalse(result.pps.isEmpty)
        XCTAssertEqual(result.sps[0] & 0x1f, 7)
        XCTAssertEqual(result.pps[0] & 0x1f, 8)
    }
    func testRejectsInvalidFrameDimensions() {
        XCTAssertThrowsError(try H264TestPattern.encode(width: 0, height: 180))
        XCTAssertThrowsError(try H264TestPattern.encode(width: 321, height: 180))
    }
}
#endif
