import XCTest
@testable import VelaCore

final class ReceiverProbeTests: XCTestCase {
    func testReadOnlyOptionsRequestAndPublicHeader() throws {
        XCTAssertTrue(String(decoding: ReceiverProbe.optionsRequest, as: UTF8.self).hasPrefix("OPTIONS * RTSP/1.0\r\n"))
        let reply = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\nPublic: OPTIONS, GET, SETUP\r\nContent-Length: 0\r\n\r\n".utf8)
        let parsed = try XCTUnwrap(ReceiverProbe.parse(reply))
        XCTAssertEqual(parsed.headers["public"], "OPTIONS, GET, SETUP")
    }
    func testIncrementalBinaryBody() throws {
        let header = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 4\r\n\r\n".utf8)
        XCTAssertNil(try ReceiverProbe.parse(header + Data([0, 1])))
        let result = try XCTUnwrap(ReceiverProbe.parse(header + Data([0, 1, 2, 3])))
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.headers["cseq"], "1")
        XCTAssertEqual(result.body, Data([0, 1, 2, 3]))
    }
    func testRejectedAndMalformedReplies() throws {
        XCTAssertEqual(try ReceiverProbe.parse(Data("RTSP/1.0 401 Unauthorized\r\n\r\n".utf8))?.status, 401)
        XCTAssertThrowsError(try ReceiverProbe.parse(Data("HTTP/1.1 200 OK\r\n\r\n".utf8)))
        XCTAssertThrowsError(try ReceiverProbe.parse(Data("RTSP/1.0 200 OK\r\nContent-Length: -1\r\n\r\n".utf8)))
        XCTAssertThrowsError(try ReceiverProbe.parse(Data("RTSP/1.0 200 OK\r\nContent-Length: 1\r\ncontent-length: 2\r\n\r\n".utf8)))
        XCTAssertThrowsError(try ReceiverProbe.parse(Data(repeating: 0, count: ReceiverProbe.maximumResponseBytes + 1)))
    }
    func testIncompleteHeader() throws {
        XCTAssertNil(try ReceiverProbe.parse(Data("RTSP/1.0 200".utf8)))
    }
}
