import Foundation

public enum TravelMode: Int, CaseIterable, Identifiable, Sendable {
    case drive = 0, bike = 1, walk = 2

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .drive: return "Drive"
        case .bike: return "Bike"
        case .walk: return "Walk"
        }
    }

    /** FOSSGIS OSRM backend (routing.openstreetmap.de), the open router Vela uses. */
    var osrmBackend: String {
        switch self {
        case .drive: return "routed-car"
        case .bike: return "routed-bike"
        case .walk: return "routed-foot"
        }
    }
}

public enum ManeuverType: String, Sendable {
    case depart, arrive, straight
    case turnLeft, turnRight, slightLeft, slightRight, sharpLeft, sharpRight, uturn
    case merge, rampLeft, rampRight, forkLeft, forkRight, keepLeft, keepRight
    case roundabout, unknown
}

public struct Maneuver: Hashable, Sendable {
    public var type: ManeuverType
    public var instruction: String
    /** Where on the route line the maneuver happens. */
    public var location: LatLng
    /** Meters from the route start to this maneuver, along the line. */
    public var alongMeters: Double
    /** Length of the step this maneuver starts. */
    public var distanceMeters: Double
    public var road: String?
    public var laneHint: String?
    /** The lanes on the way into this maneuver, left to right, when OpenStreetMap maps them. */
    public var lanes: [Lane] = []
    /** Which exit to take at a roundabout. */
    public var exit: Int?
    /** The roundabout's real layout, for drawing it: where every road leaves, and which is yours. */
    public var roundabout: RoundaboutShape?
    /** The point where the route leaves a roundabout (the router's "exit roundabout" step), shown with that roundabout's picture. */
    public var leavesRoundabout = false
    /** Only the road's name changes here ("Continue on Millbrook Flyover"): kept for the road name, never shown or said. */
    public var silent = false
    /** A slip road Google names without saying which side it leaves on ("Take the M3 slip road"): the side comes from the route line once it's placed. */
    var sideUnknown = false

    public init(type: ManeuverType, instruction: String, location: LatLng, alongMeters: Double, distanceMeters: Double,
                road: String? = nil, laneHint: String? = nil, lanes: [Lane] = [], exit: Int? = nil,
                roundabout: RoundaboutShape? = nil) {
        self.type = type
        self.instruction = instruction
        self.location = location
        self.alongMeters = alongMeters
        self.distanceMeters = distanceMeters
        self.road = road
        self.laneHint = laneHint
        self.lanes = lanes
        self.exit = exit
        self.roundabout = roundabout
    }
}

/**
 * A roundabout as you meet it: the way in at the bottom, every road around it by its angle
 * (degrees clockwise from straight ahead, so the way in is at 180), and the exit to take.
 */
public struct RoundaboutShape: Hashable, Sendable {
    /** Roads you can leave by, in the order you pass them. */
    public var exits: [Double]
    /** Which of [exits] to take. */
    public var taken: Int
    /** Roads that only come in (one way), drawn faint and not counted. */
    public var entriesOnly: [Double] = []
    /** Traffic goes round clockwise (Britain, Ireland and other keep-left countries). */
    public var clockwise: Bool
    /** False when only the exits up to yours are known (the rest of the circle is left plain). */
    public var complete: Bool
    /** A mini-roundabout (a painted circle, one lane): no "which lane" advice. */
    public var mini = false
    /** Lanes on the road in at the give-way line, when OpenStreetMap says. */
    public var entryLanes: Int?
    /** The arrows painted on those lanes, left to right ("left", "through;right"…), when OpenStreetMap maps them. */
    public var entryArrows: [String]?

    public init(exits: [Double], taken: Int, entriesOnly: [Double] = [], clockwise: Bool, complete: Bool) {
        self.exits = exits
        self.taken = taken
        self.entriesOnly = entriesOnly
        self.clockwise = clockwise
        self.complete = complete
    }

    /** How far round the exit is, the way traffic goes, from the way in: 15 to 375 (back out the same road is a full lap). */
    public func turn(_ i: Int) -> Double {
        let a = exits[i]
        let d = clockwise ? a - 180 : 180 - a
        let t = (d.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return t < 15 ? t + 360 : t
    }

    /**
     * The lane the Highway Code says to use when no lanes are mapped: left (keep-left countries)
     * for the first exit or straight on, right for anything past 12 o'clock. Mirrored where traffic keeps right.
     * 0 is the lane nearest the kerb, 1 the one nearest the middle.
     */
    public var ruleLane: Int {
        turn(taken) > 200 ? 1 : 0
    }

    /**
     * The lanes to draw when the router has none, left to right: the road's painted arrows when
     * OpenStreetMap maps them, or else by the Highway Code, as many as the road in has (two when
     * the map doesn't say). The kerb-side lane for the first exits, all but the far one for
     * straight on, and for going right round, the far one, or on three lanes or more the far half
     * (the middle lane of three takes the right too: Rownhams, M27 junction 3, 2026-10-29). Only
     * the far lane for going all the way round. Nil for a one-lane road in or a mini-roundabout,
     * where there's no lane to pick.
     */
    public func ruleLanes(leftTraffic: Bool, hint: String? = nil) -> [Lane]? {
        if mini { return nil }
        var n = entryLanes ?? 2
        guard exits.indices.contains(taken) else { return nil }
        let t = turn(taken)
        let near = leftTraffic ? "left" : "right", far = leftTraffic ? "right" : "left"
        // Google's own advice ("Use the left 3 lanes"), the few times it gives one, beats any rule:
        // on the A339 into Basingstoke's M3 junction 6 all four lanes are painted straight on, and
        // the M3 (3rd exit) is from the left three.
        if let hint, let picked = Self.hintLanes(hint, count: &n) {
            let lanes = (0..<n).map { k -> Lane in
                let a = entryArrows?.count == n ? entryArrows![k].split(separator: ";").map { $0 == "through" ? "straight" : String($0) } : []
                let ind = !a.isEmpty && !a.contains("none") ? a : k == 0 ? [near, "straight"] : k == n - 1 ? [far, "straight"] : ["straight"]
                return Lane(indications: ind, valid: picked.contains(k))
            }
            return lanes
        }
        guard n > 1 else { return nil }
        if let arrows = entryArrows, arrows.count == n {
            // Painted arrows: the lanes whose arrow points the exit's way.
            let lanes = arrows.map { a -> Lane in
                let ind = a.split(separator: ";").map { String($0) }.filter { !$0.isEmpty && $0 != "none" }
                let ok = (ind.isEmpty ? ["through"] : ind).contains { d in
                    if d.hasSuffix(near) { return t <= 150 }
                    if d == "through" { return t >= 120 && t <= 240 }
                    if d.hasSuffix(far) { return t >= 210 }
                    if d == "reverse" { return t >= 300 }
                    return false
                }
                return Lane(indications: ind.isEmpty ? ["straight"] : ind.map { $0 == "through" ? "straight" : $0 == "reverse" ? "uturn" : $0.replacingOccurrences(of: "_", with: " ") }, valid: ok)
            }
            if lanes.contains(where: \.valid) { return lanes }
        }
        // Counted from the kerb: 0 is the lane nearest it.
        let good: ClosedRange<Int>
        if t > 300 || (t > 200 && n < 3) { good = (n - 1)...(n - 1) }
        else if t > 200 { good = (n / 2)...(n - 1) }
        else if t > 135 { good = 0...max(0, n - 2) }
        else { good = 0...0 }
        let fromKerb = (0..<n).map { k -> Lane in
            let ind = k == 0 ? (n == 2 ? [near, "straight"] : [near]) : k == n - 1 ? [far] : ["straight", far]
            return Lane(indications: ind, valid: good.contains(k))
        }
        return leftTraffic ? fromKerb : fromKerb.reversed()
    }
}

extension RoundaboutShape {
    /**
     * Which lanes, left to right, Google's lane advice means, out of [count] (raised when the advice
     * needs more, as "the left 3 lanes" on a road the map gives two). Nil for "any lane" or words it
     * doesn't know.
     */
    static func hintLanes(_ hint: String, count n: inout Int) -> ClosedRange<Int>? {
        let h = hint.lowercased()
        func number(_ pattern: String) -> Int? {
            guard let r = h.range(of: pattern, options: .regularExpression) else { return nil }
            return Int(h[r].filter(\.isNumber))
        }
        if h.contains("any lane") { return nil }
        if let k = number(#"left \d lanes"#) { n = max(n, k + 1); return 0...(k - 1) }
        if let k = number(#"right \d lanes"#) { n = max(n, k + 1); return (n - k)...(n - 1) }
        if let k = number(#"lane \d(st|nd|rd|th) from the left"#) { n = max(n, k + 1); return (k - 1)...(k - 1) }
        if let k = number(#"lane \d(st|nd|rd|th) from the right"#) { n = max(n, k + 1); return (n - k)...(n - k) }
        if h.contains("left lane") { n = max(n, 2); return 0...0 }
        if h.contains("right lane") { n = max(n, 2); return (n - 1)...(n - 1) }
        if h.contains("middle lane") { guard n == 3 else { return nil }; return 1...1 }
        if h.contains("middle 2 lanes") { guard n == 4 else { return nil }; return 1...2 }
        return nil
    }
}

/** One lane: where it goes ("left", "straight", "slight right"…) and whether it's a lane for this maneuver. */
public struct Lane: Hashable, Sendable {
    public var indications: [String]
    public var valid: Bool
    public init(indications: [String], valid: Bool) {
        self.indications = indications
        self.valid = valid
    }
}

/** The posted limit from [startMeters] on, in km/h; nil where it isn't mapped. */
public struct SpeedLimit: Hashable, Sendable {
    public var startMeters: Double
    public var kmh: Double?
}

/** A congested stretch of the route: level 1 slow, 2 heavy, 3 stopped. */
public struct TrafficSpan: Hashable, Sendable {
    public var level: Int
    public var startMeters: Double
    public var lengthMeters: Double
}

public struct Route: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var mode: TravelMode
    public var polyline: [LatLng]
    public var distanceMeters: Double
    /** Seconds without traffic. */
    public var typicalSeconds: Double
    /** Seconds in current traffic, when Google knows it. */
    public var trafficSeconds: Double?
    public var summary: String?
    public var maneuvers: [Maneuver]
    public var trafficSpans: [TrafficSpan] = []
    /** Speed limits along the route, from OpenStreetMap via the open router. */
    public var speedLimits: [SpeedLimit] = []
    /** "google" or "osm". */
    public var source: String
    /** False when Google left steps out (it folds long motorway stretches away), so the turns can't be placed. */
    public var stepsComplete = true

    public var durationSeconds: Double { trafficSeconds ?? typicalSeconds }

    /** The limit at [meters] along the route. */
    public func speedLimit(at meters: Double) -> Double? {
        speedLimits.last { $0.startMeters <= meters }?.kmh
    }

    /** How much slower than usual, 0 when free-flowing: 0 green, 1 amber, 2 red. */
    public var delayLevel: Int {
        guard let t = trafficSeconds, typicalSeconds > 0 else { return 0 }
        let r = t / typicalSeconds
        return r > 1.35 ? 2 : (r > 1.12 ? 1 : 0)
    }
}

public enum Geo {
    /** Whether traffic keeps left here (Britain, Ireland, Japan, Australia and the like), roughly by area. */
    public static func drivesOnLeft(_ p: LatLng) -> Bool {
        let boxes: [(s: Double, w: Double, n: Double, e: Double)] = [
            (49.8, -11.0, 61.0, 1.8),      // Britain and Ireland
            (24.0, 122.9, 45.6, 146.0),    // Japan
            (-44.0, 112.0, -10.0, 154.0),  // Australia
            (-47.5, 166.0, -34.0, 179.0),  // New Zealand
            (6.5, 68.0, 35.5, 97.5),       // India, Sri Lanka, Bangladesh, Nepal
            (-35.0, 16.0, -22.0, 33.0),    // South Africa and neighbors
            (-11.0, 95.0, 7.5, 141.0),     // Indonesia, Malaysia, Singapore
            (5.5, 97.3, 20.5, 105.7),      // Thailand
            (22.1, 113.8, 22.6, 114.4),    // Hong Kong
            (-5.0, 33.9, 5.0, 41.9),       // Kenya
        ]
        // Gibraltar keeps right inside the first box; close enough to skip.
        return boxes.contains { p.lat >= $0.s && p.lat <= $0.n && p.lng >= $0.w && p.lng <= $0.e }
    }

    /** Cumulative distance at each vertex. */
    public static func cumulative(_ line: [LatLng]) -> [Double] {
        var out = [0.0]
        out.reserveCapacity(line.count)
        for i in 1..<max(line.count, 1) { out.append(out[i - 1] + line[i - 1].distance(to: line[i])) }
        return out
    }

    public static func length(_ line: [LatLng]) -> Double { cumulative(line).last ?? 0 }

    /** The point [meters] along [line]. */
    public static func point(along line: [LatLng], meters: Double, cumulative cum: [Double]? = nil) -> LatLng {
        guard line.count >= 2 else { return line.first ?? LatLng(0, 0) }
        let c = cum ?? cumulative(line)
        if meters <= 0 { return line[0] }
        for i in 1..<line.count where c[i] >= meters {
            let seg = c[i] - c[i - 1]
            let f = seg > 0 ? (meters - c[i - 1]) / seg : 0
            let a = line[i - 1], b = line[i]
            return LatLng(a.lat + (b.lat - a.lat) * f, a.lng + (b.lng - a.lng) * f)
        }
        return line[line.count - 1]
    }

    /** The part of [line] between two along-distances. */
    public static func slice(_ line: [LatLng], from: Double, to: Double, cumulative cum: [Double]? = nil) -> [LatLng] {
        guard line.count >= 2, to > from else { return [] }
        let c = cum ?? cumulative(line)
        var out = [point(along: line, meters: from, cumulative: c)]
        for i in 0..<line.count where c[i] > from && c[i] < to { out.append(line[i]) }
        out.append(point(along: line, meters: to, cumulative: c))
        return out
    }

    /** Where [p] falls on [line]: meters along it, and how far off it. */
    public static func project(_ p: LatLng, on line: [LatLng], cumulative cum: [Double]? = nil) -> (along: Double, offset: Double) {
        guard line.count >= 2 else { return (0, line.first.map { p.distance(to: $0) } ?? .greatestFiniteMagnitude) }
        let c = cum ?? cumulative(line)
        let k = cos(p.lat * .pi / 180) * 111_320.0
        var best = (along: 0.0, offset: Double.greatestFiniteMagnitude)
        for i in 0..<(line.count - 1) {
            let a = line[i], b = line[i + 1]
            let ax = (a.lng - p.lng) * k, ay = (a.lat - p.lat) * 110_540
            let bx = (b.lng - p.lng) * k, by = (b.lat - p.lat) * 110_540
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? min(max(-(ax * dx + ay * dy) / len2, 0), 1) : 0
            let x = ax + t * dx, y = ay + t * dy
            let d = (x * x + y * y).squareRoot()
            if d < best.offset { best = (c[i] + t * (c[i + 1] - c[i]), d) }
        }
        return best
    }

    /** Compass bearing from a to b, degrees. */
    /**
     * Which side of the road [p] is on at the end of [line] ("your destination is on the left"):
     * nil when it's on the line itself or behind/past its end.
     */
    public static func sideAtEnd(_ p: LatLng, of line: [LatLng]) -> String? {
        let cum = cumulative(line)
        guard let total = cum.last, total > 20 else { return nil }
        let a = point(along: line, meters: max(0, total - 30), cumulative: cum), b = line[line.count - 1]
        let k = cos(b.lat * .pi / 180) * 111_320.0
        let dx = (b.lng - a.lng) * k, dy = (b.lat - a.lat) * 110_540
        let px = (p.lng - a.lng) * k, py = (p.lat - a.lat) * 110_540
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 5 else { return nil }
        // Sideways from the road, and not well beyond its end.
        let across = (dx * py - dy * px) / len
        let ahead = (dx * px + dy * py) / len
        guard abs(across) > 8, ahead > -20, ahead < len + 60 else { return nil }
        return across > 0 ? "left" : "right"
    }

    public static func bearing(_ a: LatLng, _ b: LatLng) -> Double {
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180, dl = (b.lng - a.lng) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /** Decode an encoded polyline (precision 5 or 6). */
    public static func decodePolyline(_ s: String, precision: Double = 1e6) -> [LatLng] {
        var out: [LatLng] = []
        let bytes = Array(s.utf8)
        var i = 0, lat = 0, lng = 0
        func next() -> Int? {
            var result = 0, shift = 0
            while i < bytes.count {
                let b = Int(bytes[i]) - 63
                i += 1
                result |= (b & 0x1f) << shift
                shift += 5
                if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : (result >> 1) }
            }
            return nil
        }
        while i < bytes.count {
            guard let dlat = next(), let dlng = next() else { break }
            lat += dlat
            lng += dlng
            out.append(LatLng(Double(lat) / precision, Double(lng) / precision))
        }
        return out
    }
}
