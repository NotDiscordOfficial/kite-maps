import Foundation

/// A deliberately read-only RTSP /info probe. It does not authenticate or create a CarPlay session.
public enum ReceiverProbe {
    public static let request = Data("GET /info RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: Kite-Receiver-Diagnostics/1\r\n\r\n".utf8)
    /// OPTIONS asks the endpoint which methods it supports. It does not begin a session.
    public static let optionsRequest = Data("OPTIONS * RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: Kite-Receiver-Diagnostics/1\r\n\r\n".utf8)
    public static let maximumResponseBytes = 128 * 1024

    public struct Response: Equatable {
        public let status: Int
        public let headers: [String: String]
        public let body: Data
    }

    public enum ParseError: Error, Equatable { case oversized, invalidHeader, invalidLength }

    /// Returns nil for incomplete responses; limits allocations from untrusted local devices.
    public static func parse(_ data: Data) throws -> Response? {
        guard data.count <= maximumResponseBytes else { throw ParseError.oversized }
        let separator = Data([13, 10, 13, 10])
        guard let end = data.range(of: separator) else { return nil }
        guard let header = String(data: data[..<end.lowerBound], encoding: .utf8) else { throw ParseError.invalidHeader }
        let lines = header.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("RTSP/"), let status = Int(parts[1]), (100...999).contains(status) else {
            throw ParseError.invalidHeader
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw ParseError.invalidHeader }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, headers[key] == nil else { throw ParseError.invalidHeader }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length: Int
        if let raw = headers["content-length"] {
            guard let value = Int(raw), value >= 0, value <= maximumResponseBytes else { throw ParseError.invalidLength }
            length = value
        } else { length = 0 }
        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return nil }
        let bodyEnd = data.index(bodyStart, offsetBy: length)
        return Response(status: status, headers: headers, body: Data(data[bodyStart..<bodyEnd]))
    }
}
