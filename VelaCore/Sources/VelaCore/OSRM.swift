import Foundation

/**
 * The FOSSGIS OSRM servers (routing.openstreetmap.de), which Vela uses for turn-by-turn steps.
 * Here they're the open-data router: used when Google gives no route.
 */
public enum OSRM {
    static let userAgent = "VelaMaps-iOS/0.2 (+https://github.com/matteofx1/vela-ios)"

    public static func route(from a: LatLng, to b: LatLng, mode: TravelMode, via: [LatLng] = [],
                             heading: Double? = nil) async throws -> [Route] {
        var r = URLRequest(url: routeURL(from: a, to: b, mode: mode, via: via, heading: heading))
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: r)
        return parse(data, mode: mode)
    }

    /**
     * With [heading] (the way the car is moving), the route starts off that way, the way Google and
     * Waze reroute: never a U-turn back down the road you're already on.
     */
    static func routeURL(from a: LatLng, to b: LatLng, mode: TravelMode, via: [LatLng] = [], heading: Double? = nil) -> URL {
        let profile = mode == .drive ? "driving" : (mode == .bike ? "bike" : "foot")
        let pts = [a] + via + [b]
        let coords = pts.map { "\($0.lng),\($0.lat)" }.joined(separator: ";")
        var s = "https://routing.openstreetmap.de/\(mode.osrmBackend)/route/v1/\(profile)/\(coords)" +
            "?overview=full&geometries=polyline6&steps=true&alternatives=\(mode == .drive && via.isEmpty)"
        if let heading {
            s += "&bearings=\(Int(heading.rounded()) % 360),60" + String(repeating: ";", count: pts.count - 1)
        }
        return URL(string: s)!
    }

    /**
     * The open router's turn-by-turn for exactly [line] (Google's route): its map matching follows the
     * line point by point, so every step is on a road the blue line really takes. Routing through a
     * few points instead (routeVia) let it pick its own roads between them, and Kite then called out
     * turns the line never made and missed ones it did.
     */
    public static func match(_ line: [LatLng], mode: TravelMode) async throws -> Route? {
        guard line.count >= 2, let url = matchURL(line, mode: mode) else { return nil }
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: r)
        // One unbroken match only: a gap means part of the line couldn't be followed.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let matchings = root["matchings"] as? [[String: Any]], matchings.count == 1 else { return nil }
        let routes = try JSONSerialization.data(withJSONObject: ["routes": matchings])
        guard let m = parse(routes, mode: mode).first else { return nil }
        let total = Geo.length(line)
        return abs(m.distanceMeters - total) < max(150, total * 0.04) ? m : nil
    }

    /** Points along the line every 150 m or so (at most 100, the server's limit), first and last kept. */
    public static func matchURL(_ line: [LatLng], mode: TravelMode) -> URL? {
        let cum = Geo.cumulative(line)
        let total = cum.last ?? 0
        let n = min(99, max(1, Int(total / 150)))
        let pts = (0...n).map { Geo.point(along: line, meters: total * Double($0) / Double(n), cumulative: cum) }
        let profile = mode == .drive ? "driving" : (mode == .bike ? "bike" : "foot")
        let coords = pts.map { String(format: "%.6f,%.6f", $0.lng, $0.lat) }.joined(separator: ";")
        let radii = Array(repeating: "25", count: pts.count).joined(separator: ";")
        return URL(string: "https://routing.openstreetmap.de/\(mode.osrmBackend)/match/v1/\(profile)/\(coords)" +
                   "?overview=full&geometries=polyline6&steps=true&tidy=true&gaps=ignore&radiuses=\(radii)&waypoints=0;\(pts.count - 1)")
    }

    /**
     * The open router forced through points sampled off [line] (Google's route), so its
     * turn-by-turn follows the same roads, the way Vela gets readable steps for Google routes.
     */
    public static func routeVia(_ line: [LatLng], mode: TravelMode) async throws -> Route? {
        guard line.count >= 2 else { return nil }
        let cum = Geo.cumulative(line)
        let total = cum.last ?? 0
        let vias = min(12, Int(total / 1_500))
        var pts = [line[0]]
        var bearings = [bearing(line, cum, at: 0)]
        for i in stride(from: 1, through: vias, by: 1) {
            let m = total * Double(i) / Double(vias + 1)
            pts.append(Geo.point(along: line, meters: m, cumulative: cum))
            bearings.append(bearing(line, cum, at: m))
        }
        pts.append(line[line.count - 1])
        bearings.append(nil)
        let profile = mode == .drive ? "driving" : (mode == .bike ? "bike" : "foot")
        let coords = pts.map { String(format: "%.6f,%.6f", $0.lng, $0.lat) }.joined(separator: ";")
        let b = bearings.map { $0.map { "\(Int($0)),45" } ?? "" }.joined(separator: ";")
        let radii = pts.indices.map { $0 == 0 || $0 == pts.count - 1 ? "unlimited" : "30" }.joined(separator: ";")
        let base = "https://routing.openstreetmap.de/\(mode.osrmBackend)/route/v1/\(profile)/\(coords)" +
            "?overview=full&geometries=polyline6&steps=true&continue_straight=true&bearings=\(b)&radiuses=\(radii)"
        guard let url = URL(string: base) else { return nil }
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: r)
        return parse(data, mode: mode).first
    }

    private static func bearing(_ line: [LatLng], _ cum: [Double], at m: Double) -> Double? {
        let a = Geo.point(along: line, meters: max(0, m - 10), cumulative: cum)
        let b = Geo.point(along: line, meters: min(cum.last ?? 0, m + 10), cumulative: cum)
        return a.distance(to: b) > 1 ? Geo.bearing(a, b) : nil
    }

    static func parse(_ data: Data, mode: TravelMode) -> [Route] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = root["routes"] as? [[String: Any]] else { return [] }
        return routes.compactMap { r in
            guard let geo = r["geometry"] as? String,
                  let distance = r["distance"] as? Double,
                  let duration = r["duration"] as? Double else { return nil }
            let line = Geo.decodePolyline(geo, precision: 1e6)
            guard line.count >= 2 else { return nil }
            let cum = Geo.cumulative(line)
            var maneuvers: [Maneuver] = []
            var mergeSides: [Int: String] = [:]
            var nameOnly: Set<Int> = []
            var along = 0.0
            var roads: [String: Double] = [:]
            let legs = (r["legs"] as? [[String: Any]]) ?? []
            for (li, leg) in legs.enumerated() {
                let steps = (leg["steps"] as? [[String: Any]]) ?? []
                for (si, step) in steps.enumerated() {
                    let m = step["maneuver"] as? [String: Any] ?? [:]
                    let type = m["type"] as? String ?? ""
                    // A route through vias stops and restarts at each one: those aren't turns.
                    if (type == "arrive" && li < legs.count - 1) || (type == "depart" && li > 0) {
                        if let i = maneuvers.indices.last { maneuvers[i].distanceMeters += step["distance"] as? Double ?? 0 }
                        along += step["distance"] as? Double ?? 0
                        continue
                    }
                    let modifier = m["modifier"] as? String
                    let ref0 = (step["ref"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    // A motorway is known by its number ("M271"), not its name ("Nursling Spur Motorway").
                    let ref = ref0?.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }
                    let motorway = ref.flatMap { r in r.range(of: #"^(M\d+|A\d+\(M\))$"#, options: .regularExpression) != nil ? r : nil }
                    let name = motorway ?? (step["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    let dist = step["distance"] as? Double ?? 0
                    if let n = name ?? ref { roads[n, default: 0] += dist }
                    let loc = (m["location"] as? [Double]).map { LatLng($0[1], $0[0]) } ?? Geo.point(along: line, meters: along, cumulative: cum)
                    let mt = maneuverType(type, modifier, leftTraffic: Geo.drivesOnLeft(loc))
                    let signs = Signs(destinations: step["destinations"] as? String, exits: step["exits"] as? String,
                                      from: maneuvers.last?.road)
                    var man = Maneuver(type: mt, instruction: instruction(type: type, modifier: modifier, road: name ?? ref,
                                                                         exit: m["exit"] as? Int, mode: mode, signs: signs),
                                       location: loc, alongMeters: min(along, cum.last ?? along),
                                       distanceMeters: dist, road: name ?? ref, laneHint: nil)
                    man.lanes = lanes(step)
                    man.exit = m["exit"] as? Int
                    if type == "roundabout" || type == "rotary" {
                        // The lanes for a roundabout are sometimes mapped on the road leading up to it.
                        if man.lanes.isEmpty, si > 0, let last = (steps[si - 1]["intersections"] as? [[String: Any]])?.last {
                            man.lanes = approachLanes(last, roundabout: loc, modifier: modifier, leftTraffic: Geo.drivesOnLeft(loc))
                        }
                        // A first sketch from the router; OpenStreetMap fills in the whole circle later.
                        man.roundabout = roundaboutSketch(step, next: si + 1 < steps.count ? steps[si + 1] : nil,
                                                          clockwise: Geo.drivesOnLeft(loc))
                    }
                    if type == "exit roundabout" || type == "exit rotary" {
                        // Still going round: keep the roundabout's exit number until off it.
                        man.leavesRoundabout = true
                        man.lanes = []
                        if let prev = maneuvers.last, prev.type == .roundabout {
                            man.exit = man.exit ?? prev.exit
                            man.roundabout = prev.roundabout
                        }
                    }
                    if type == "merge", let modifier { mergeSides[maneuvers.count] = modifier }
                    if type == "new name" || type == "continue", (modifier ?? "straight") == "straight" { nameOnly.insert(maneuvers.count) }
                    maneuvers.append(man)
                    along += dist
                }
            }
            for i in nameOnly where i > 0 && maneuvers[i].lanes.isEmpty { maneuvers[i].silent = true }
            maneuvers = keepLaneThroughMerges(maneuvers, mergeSides: mergeSides)
            if let last = maneuvers.indices.last {
                maneuvers[last].alongMeters = cum.last ?? along
            }
            let via = roads.max { $0.value < $1.value }?.key
            var route = Route(mode: mode, polyline: line, distanceMeters: distance, typicalSeconds: duration,
                              trafficSeconds: nil, summary: via, maneuvers: maneuvers, source: "osm")
            route.speedLimits = speedLimits(legs, line: line, cumulative: cum)
            return route
        }
    }

    /**
     * The roundabout as far as the router knows it: the exits passed on the way round (side roads
     * you could take at each point on the circle) and the one taken, placed around a circle
     * fitted through those points. The roads after yours aren't known, so it's marked incomplete.
     */
    static func roundaboutSketch(_ step: [String: Any], next: [String: Any]?, clockwise: Bool) -> RoundaboutShape? {
        guard let ints = step["intersections"] as? [[String: Any]], ints.count >= 1,
              let exitInt = (next?["intersections"] as? [[String: Any]])?.first else { return nil }
        func loc(_ x: [String: Any]) -> LatLng? {
            (x["location"] as? [Double]).flatMap { $0.count == 2 ? LatLng($0[1], $0[0]) : nil }
        }
        guard let entry = loc(ints[0]), let out = loc(exitInt) else { return nil }
        var passed: [LatLng] = []
        var inOnly: [LatLng] = []
        for x in ints.dropFirst() {
            guard let p = loc(x), let bearings = x["bearings"] as? [Int] else { continue }
            let entries = x["entry"] as? [Bool] ?? []
            let into = x["in"] as? Int, onward = x["out"] as? Int
            for k in bearings.indices where k != into && k != onward {
                if k < entries.count && entries[k] { passed.append(p) } else { inOnly.append(p) }
            }
        }
        let ring = [entry] + passed + inOnly + [out]
        guard let center = fitCircle(ring) else { return nil }
        let e = Geo.bearing(center, entry)
        func rel(_ p: LatLng) -> Double {
            let a = Geo.bearing(center, p) - e + 180
            return (a.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        }
        let exits = passed.map(rel) + [rel(out)]
        return RoundaboutShape(exits: exits, taken: exits.count - 1, entriesOnly: inOnly.map(rel), clockwise: clockwise, complete: false)
    }

    /** The middle of the circle best through [pts] (least squares), or nil when they don't make one. */
    static func fitCircle(_ pts: [LatLng]) -> LatLng? {
        guard pts.count >= 3 else { return nil }
        let o = pts[0]
        let k = cos(o.lat * .pi / 180) * 111_320.0
        let xy = pts.map { (x: ($0.lng - o.lng) * k, y: ($0.lat - o.lat) * 110_540) }
        // Solve for x² + y² + Dx + Ey + F = 0.
        var a = [[Double]](repeating: [0, 0, 0], count: 3)
        var b = [0.0, 0.0, 0.0]
        for p in xy {
            let row = [p.x, p.y, 1.0]
            let z = -(p.x * p.x + p.y * p.y)
            for i in 0..<3 {
                for j in 0..<3 { a[i][j] += row[i] * row[j] }
                b[i] += row[i] * z
            }
        }
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let d = det(a)
        guard abs(d) > 1e-6 else { return nil }
        func col(_ c: Int) -> [[Double]] { a.enumerated().map { i, r in r.enumerated().map { j, v in j == c ? b[i] : v } } }
        let dd = det(col(0)) / d, ee = det(col(1)) / d
        let cx = -dd / 2, cy = -ee / 2
        let r = (xy.map { (($0.x - cx) * ($0.x - cx) + ($0.y - cy) * ($0.y - cy)).squareRoot() }.reduce(0, +)) / Double(xy.count)
        guard r > 3, r < 300 else { return nil }
        return LatLng(o.lat + cy / 110_540, o.lng + cx / k)
    }

    /** The turn lanes at a step's maneuver point (its first intersection), left to right. */
    static func lanes(_ step: [String: Any]) -> [Lane] {
        guard let first = (step["intersections"] as? [[String: Any]])?.first,
              let raw = first["lanes"] as? [[String: Any]], raw.count > 1 else { return [] }
        let lanes = raw.map { Lane(indications: $0["indications"] as? [String] ?? ["none"], valid: $0["valid"] as? Bool ?? false) }
        // All lanes valid tells the driver nothing.
        return lanes.allSatisfy(\.valid) ? [] : lanes
    }

    /**
     * A slip road that joins a main road and then leaves it again at the next exit on the same side
     * (into Redbridge Road from the A33, then off again for the A33): the slip road's lane just carries
     * on to that exit, so there's nothing to merge. Drop the "Merge onto…" step and say to stay in
     * that lane for the exit instead, unless lanes are mapped there.
     */
    static func keepLaneThroughMerges(_ steps: [Maneuver], mergeSides: [Int: String]) -> [Maneuver] {
        var out: [Maneuver] = []
        var dropped = false
        for (i, m) in steps.enumerated() {
            if let side = mergeSides[i], i > 0, let n = steps[(i + 1)...].firstIndex(where: { !$0.silent }) {
                let next = steps[n]
                // Merging to the right means joining from the left, so the lane is the left one.
                let fromLeft = side.hasSuffix("right")
                let exitSameSide = fromLeft ? [ManeuverType.rampLeft, .forkLeft, .keepLeft].contains(next.type)
                                            : [ManeuverType.rampRight, .forkRight, .keepRight].contains(next.type)
                if exitSameSide, next.alongMeters - m.alongMeters < 1_000, !out.isEmpty {
                    out[out.count - 1].distanceMeters += m.distanceMeters
                    dropped = true
                    continue
                }
            }
            var m = m
            if dropped, m.silent { out.append(m); continue }
            if dropped, m.lanes.isEmpty {
                // The merge before this exit was dropped: show its lane.
                let left = [ManeuverType.rampLeft, .forkLeft, .keepLeft].contains(m.type)
                let exit = Lane(indications: [left ? "slight left" : "slight right"], valid: true)
                let main = Lane(indications: ["straight"], valid: false)
                m.lanes = left ? [exit, main] : [main, exit]
            }
            dropped = false
            out.append(m)
        }
        return out
    }

    /**
     * Lanes mapped at a junction just before a roundabout, marked again for the way round it.
     * They only belong to the roundabout when that junction has no other road to take: where one
     * leaves (a slip road off the M271 before Redbridge, say), they're that junction's lanes, and
     * the lane to be in at the roundabout is left to the Highway Code instead.
     */
    static func approachLanes(_ x: [String: Any], roundabout: LatLng, modifier: String?, leftTraffic: Bool) -> [Lane] {
        guard let raw = x["lanes"] as? [[String: Any]], raw.count > 1,
              let at = (x["location"] as? [Double]).map({ LatLng($0[1], $0[0]) }), at.distance(to: roundabout) < 200,
              let out = x["out"] as? Int else { return [] }
        let entry = x["entry"] as? [Bool] ?? []
        let into = x["in"] as? Int
        if entry.indices.contains(where: { $0 != out && $0 != into && entry[$0] }) { return [] }
        // The router marked them for going straight on at that junction; mark them for the roundabout exit.
        let way: String
        switch modifier ?? "straight" {
        case let m where m.hasSuffix("left"): way = "left"
        case let m where m.hasSuffix("right"): way = "right"
        case "uturn": way = leftTraffic ? "right" : "left"
        default: way = "straight"
        }
        let lanes = raw.map { r -> Lane in
            let ind = r["indications"] as? [String] ?? ["none"]
            return Lane(indications: ind, valid: ind.contains { $0 == way || $0.hasSuffix(" " + way) })
        }
        let valid = lanes.filter(\.valid).count
        return valid == 0 || valid == lanes.count ? [] : lanes
    }

    /**
     * Per-segment `maxspeed` annotations ({speed, unit} or {unknown}/{none}) turned into
     * limit changes along the line. The legs' segments run end to end along the overview line.
     */
    static func speedLimits(_ legs: [[String: Any]], line: [LatLng], cumulative cum: [Double]) -> [SpeedLimit] {
        var out: [SpeedLimit] = []
        var seg = 0
        for leg in legs {
            let speeds = ((leg["annotation"] as? [String: Any])?["maxspeed"] as? [[String: Any]]) ?? []
            for sp in speeds {
                defer { seg += 1 }
                guard seg < cum.count else { break }
                var kmh: Double?
                if let v = sp["speed"] as? Double {
                    kmh = (sp["unit"] as? String) == "mph" ? v * 1.609344 : v
                }
                if out.last.map({ $0.kmh != kmh }) ?? true {
                    out.append(SpeedLimit(startMeters: cum[seg], kmh: kmh))
                }
            }
        }
        return out.contains { $0.kmh != nil } ? out : []
    }

    static func maneuverType(_ type: String, _ modifier: String?, leftTraffic: Bool = false) -> ManeuverType {
        switch type {
        case "depart": return .depart
        case "arrive": return .arrive
        case "roundabout", "rotary", "roundabout turn", "exit roundabout", "exit rotary": return .roundabout
        case "merge": return .merge
        case "on ramp", "off ramp":
            // Straight on (no side): the side traffic keeps to, where slip roads leave.
            let m = modifier ?? ""
            return m.contains("left") ? .rampLeft : m.contains("right") ? .rampRight : (leftTraffic ? .rampLeft : .rampRight)
        case "fork":
            return (modifier ?? "").contains("left") ? .forkLeft : .forkRight
        default: break
        }
        switch modifier {
        case "left": return .turnLeft
        case "right": return .turnRight
        case "slight left": return type == "continue" || type == "new name" ? .keepLeft : .slightLeft
        case "slight right": return type == "continue" || type == "new name" ? .keepRight : .slightRight
        case "sharp left": return .sharpLeft
        case "sharp right": return .sharpRight
        case "uturn": return .uturn
        default: return .straight
        }
    }

    /** What the road signs at a junction say, and the road being left, for slip road wording. */
    struct Signs {
        var destinations: String?
        var exits: String?
        /** The road before this step, so leaving the M27 isn't read out as "toward M27". */
        var from: String?

        /** "Eastleigh and Southampton" from "A335: Eastleigh, Southampton"; the road numbers if that's all there is. */
        var toward: String? {
            guard let d = destinations?.replacingOccurrences(of: ";", with: ",").trimmingCharacters(in: .whitespaces), !d.isEmpty else { return nil }
            let parts = d.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            // UK signs put a road reached later in brackets, "(A32) Alton": the place is what's said.
            let names = (parts.count == 2 ? parts[1] : parts[0]).split(separator: ",")
                .map { $0.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let refs = parts.count == 2 ? parts[0].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } : []
            var pick = Array(names.prefix(2))
            if pick.isEmpty { pick = Array(refs.prefix(2)) }
            guard !pick.isEmpty else { return nil }
            return pick.count == 2 ? "\(pick[0]) and \(pick[1])" : pick[0]
        }

        /** Junction number from the sign, like "5" or "9A". */
        var number: String? {
            exits?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    static func instruction(type: String, modifier: String?, road: String?, exit: Int?, mode: TravelMode,
                            signs: Signs = Signs()) -> String {
        let onto = road.map { " onto \($0)" } ?? ""
        let dir = modifier ?? "straight"
        // A slip road often carries the motorway's name: don't say "onto M27" while leaving the M27.
        let newRoad = road.flatMap { $0 == signs.from ? nil : $0 }
        switch type {
        case "depart":
            let verb = mode == .drive ? "Drive" : (mode == .bike ? "Ride" : "Walk")
            return road.map { "\(verb) along \($0)" } ?? "Head out"
        case "arrive": return "You have arrived"
        case "roundabout turn" where exit == nil:
            // A mini-roundabout the router treats as a junction, with no exit count: say the turn.
            let turn = dir.contains("left") ? "turn left" : dir.contains("right") ? "turn right" : "go straight on"
            return "At the roundabout, \(turn)" + onto
        case "roundabout", "rotary", "roundabout turn":
            // A named roundabout ("Millbrook Roundabout") is where you are, not a road to go onto.
            if let r = road, r.lowercased().contains("roundabout") {
                return exit.map { "At \(r), take the \(ordinal($0)) exit" } ?? "Go straight through \(r)"
            }
            let n = exit.map { "take the \(ordinal($0)) exit" } ?? "go straight through"
            return "At the roundabout, \(n)" + onto
        case "exit roundabout", "exit rotary": return "Exit the roundabout" + onto
        case "merge": return "Merge" + onto
        case "on ramp":
            if let r = newRoad { return "Take the slip road onto \(r)" }
            return "Take the slip road" + (signs.toward.map { " toward \($0)" } ?? "")
        case "off ramp":
            let base = signs.number.map { "Take exit \($0)" } ?? "Take the exit"
            if let t = signs.toward { return base + " toward \(t)" }
            return base + (newRoad.map { " onto \($0)" } ?? "")
        case "fork":
            // Leaving the M27 by a slip road that still carries its name isn't "onto M27".
            let toward = signs.toward.map { " toward \($0)" } ?? ""
            return "Keep \(dir.contains("left") ? "left" : "right") at the fork" + (newRoad.map { " onto \($0)" } ?? toward)
        case "end of road": return "At the end of the road, turn \(dir.replacingOccurrences(of: "slight ", with: ""))" + onto
        case "continue", "new name":
            let stay = road.map { " to stay on \($0)" } ?? ""
            if dir == "uturn" { return "Make a U-turn" + (road.map { " on \($0)" } ?? "") }
            if dir.contains("slight") { return "Keep \(dir.contains("left") ? "left" : "right")" + (type == "continue" ? stay : onto) }
            if dir.contains("left") || dir.contains("right") {
                let turn = "Turn \(dir)"
                return turn + (type == "continue" ? stay : onto)
            }
            return "Continue" + (road.map { " on \($0)" } ?? "")
        default:
            switch dir {
            case "uturn": return "Make a U-turn" + onto
            case "straight": return "Continue straight" + onto
            default: return "Turn \(dir)" + onto
            }
        }
    }

    private static func ordinal(_ n: Int) -> String {
        switch n {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(n)th"
        }
    }
}

/** What the app asks for routes: Google (traffic, alternates), else the open router. */
public enum Directions {
    public struct Result: Sendable {
        public var routes: [Route]
        public var error: String?
        public init(routes: [Route], error: String? = nil) {
            self.routes = routes
            self.error = error
        }
    }

    public static func routes(from a: LatLng, to b: LatLng, mode: TravelMode,
                              avoidHighways: Bool = false, avoidTolls: Bool = false,
                              useGoogle: Bool = true, via: [LatLng] = [], heading: Double? = nil,
                              alternatives: Bool = false) async -> Result {
        // Ask both at once: Google's route knows traffic, OSRM's steps read better (Vela puts
        // the open router's turn-by-turn on Google's line the same way).
        let osrmTask = Task { try await OSRM.route(from: a, to: b, mode: mode, via: via, heading: heading) }
        var err: String?
        if useGoogle { do {
            var g = try await GoogleClient.shared.directions(from: a, to: b, mode: mode,
                                                              avoidHighways: avoidHighways, avoidTolls: avoidTolls, via: via)
            if let heading {
                // A reroute while driving: Google doesn't know which way the car faces, so drop its
                // routes that start back the way the car came; only the first one is driven, so skip the rest.
                var ahead = g.filter { !startsBehind($0.polyline, heading: heading) }
                // The open router can't avoid motorways or tolls: rather Google's turn round than those.
                if ahead.isEmpty && (avoidHighways || avoidTolls) { ahead = g }
                // Planning a trip while already moving keeps the choice of routes; a reroute only needs one.
                g = alternatives ? ahead : Array(ahead.prefix(1))
            }
            if !g.isEmpty {
                // One at a time: the FOSSGIS server turns away bursts.
                // Rerouting at speed, a slow open router (weak signal, a busy server) mustn't hold
                // the new route back: after a few seconds Google's own steps are driven instead.
                let reroute = heading != nil && !alternatives
                let wait: Double = reroute ? 5 : 25
                var vias: [Int: Route] = [:]
                for i in g.indices {
                    let line = g[i].polyline
                    if let r = (await deadline(wait, { try? await OSRM.routeVia(line, mode: mode) })).flatMap({ $0 }) { vias[i] = r }
                }
                let plain: [Route] = (await deadline(wait, { try? await osrmTask.value })).flatMap { $0 } ?? []
                var spare = plain
                for i in g.indices {
                    if var steps = StepMerge.adopt(vias[i].map { [$0] + plain } ?? plain, onto: g[i].polyline) {
                        // Google's step positions are only trustworthy when its steps cover the whole line.
                        if g[i].stepsComplete {
                            StepMerge.addGoogleLaneHints(&steps, from: g[i].maneuvers)
                            StepMerge.addGoogleExits(&steps, from: g[i].maneuvers)
                        }
                        g[i].maneuvers = steps
                        g[i].stepsComplete = true
                    } else if !g[i].stepsComplete, !spare.isEmpty {
                        // Google's own steps have a gap, so its turns would be called in the wrong places:
                        // drive the open router's route instead, keeping Google's traffic estimate.
                        var o = spare.removeFirst()
                        if let t = g[i].trafficSeconds, g[i].typicalSeconds > 0 { o.trafficSeconds = o.typicalSeconds * t / g[i].typicalSeconds }
                        g[i] = o
                    }
                }
                for i in g.indices {
                    // Whatever the steps came from, the picture's number matches the words.
                    for j in g[i].maneuvers.indices where g[i].maneuvers[j].type == .roundabout && g[i].maneuvers[j].exit == nil {
                        g[i].maneuvers[j].exit = DirectionsParser.exitNumber(in: g[i].maneuvers[j].instruction)
                    }
                    g[i] = Roundabouts.settle(g[i])
                    // Britain and Ireland ("slip road" is British; Australia says "ramp" too).
                    if (49.8...61).contains(a.lat), (-11...2).contains(a.lng) {
                        for j in g[i].maneuvers.indices { g[i].maneuvers[j].instruction = British.words(g[i].maneuvers[j].instruction) }
                    }
                }
                return Result(routes: g)
            }
        } catch {
            err = error.localizedDescription
        } }
        do {
            let o = try await osrmTask.value
            if !o.isEmpty { return Result(routes: o.map(Roundabouts.settle)) }
        } catch {
            err = error.localizedDescription
        }
        return Result(routes: [], error: err ?? "No route found.")
    }
}

/** [op]'s answer, or nil if it takes longer than [seconds]. */
func deadline<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await op() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

extension Directions {
    /** Whether [line] sets off more than a right angle away from [heading]: back the way the car came. */
    public static func startsBehind(_ line: [LatLng], heading: Double) -> Bool {
        guard line.count >= 2 else { return false }
        let cum = Geo.cumulative(line)
        let end = Geo.point(along: line, meters: min(40, cum.last ?? 0), cumulative: cum)
        guard line[0].distance(to: end) > 5 else { return false }
        let diff = abs((Geo.bearing(line[0], end) - heading + 540).truncatingRemainder(dividingBy: 360) - 180)
        return diff > 100
    }
}

/** Puts an open router's steps on Google's route line, when they follow the same roads. */
public enum StepMerge {
    /** The steps of the candidate that best fits [line], placed on it; nil if none fits well. */
    public static func adopt(_ candidates: [Route], onto line: [LatLng]) -> [Maneuver]? {
        guard line.count >= 2 else { return nil }
        let cum = Geo.cumulative(line)
        let total = cum.last ?? 0
        var best: [Maneuver]?
        var bestScore = 0.0
        for o in candidates {
            // Only a route on the same roads all the way, checked both ways: one that strays (its own
            // way round somewhere), or skips a bit of the line (a U-turn where the line goes round a
            // roundabout), would call out turns the blue line never makes.
            guard follows(o.polyline, line, cumulative: cum), follows(line, o.polyline, cumulative: Geo.cumulative(o.polyline)) else { continue }
            let mids = o.maneuvers.filter { $0.type != .depart && $0.type != .arrive }
            var placed: [Maneuver] = []
            var last = 0.0
            for m in mids {
                let p = Geo.project(m.location, on: line, cumulative: cum)
                guard p.offset < 40, p.along >= last - 30, p.along < total - 5 else { continue }
                last = max(last, p.along)
                var m2 = m
                m2.alongMeters = last
                m2.location = Geo.point(along: line, meters: last, cumulative: cum)
                placed.append(m2)
            }
            let score = mids.isEmpty ? (abs(Geo.length(o.polyline) - total) < 100 ? 1 : 0) : Double(placed.count) / Double(mids.count)
            guard score > bestScore else { continue }
            bestScore = score
            var depart = o.maneuvers.first { $0.type == .depart }
                ?? Maneuver(type: .depart, instruction: "Head out", location: line[0], alongMeters: 0, distanceMeters: 0, road: nil, laneHint: nil)
            depart.alongMeters = 0
            depart.location = line[0]
            var arrive = o.maneuvers.last { $0.type == .arrive }
                ?? Maneuver(type: .arrive, instruction: "You have arrived", location: line[line.count - 1], alongMeters: total, distanceMeters: 0, road: nil, laneHint: nil)
            arrive.alongMeters = total
            arrive.location = line[line.count - 1]
            var all = [depart] + placed + [arrive]
            for i in 0..<(all.count - 1) { all[i].distanceMeters = all[i + 1].alongMeters - all[i].alongMeters }
            all[all.count - 1].distanceMeters = 0
            best = all
        }
        return bestScore >= 0.7 ? best : nil
    }

    /** Whether [route] keeps within 30 m of [line] everywhere (checked every 50 m), ends aside. */
    static func follows(_ route: [LatLng], _ line: [LatLng], cumulative cum: [Double]) -> Bool {
        guard route.count >= 2 else { return false }
        let rc = Geo.cumulative(route)
        let total = rc.last ?? 0
        var m = 60.0
        while m < total - 60 {
            if Geo.project(Geo.point(along: route, meters: m, cumulative: rc), on: line, cumulative: cum).offset > 30 { return false }
            m += 50
        }
        return true
    }

    /**
     * Google's own lane advice ("Use the right lane to merge onto Redbridge Rd") on the step at the
     * same place, where the open map has no lanes mapped.
     */
    /**
     * Google's exit count for each roundabout, where the open router has none or a different one:
     * on 2026-10-27's drives the router said "go straight through" or "1st exit" at Millbrook and
     * Redbridge where Google (and the signs) say 2nd. The open router's road name is kept.
     */
    public static func addGoogleExits(_ steps: inout [Maneuver], from google: [Maneuver]) {
        for i in steps.indices where steps[i].type == .roundabout && !steps[i].leavesRoundabout {
            let near = google.filter { $0.type == .roundabout && $0.exit != nil && abs($0.alongMeters - steps[i].alongMeters) < 120 }
            guard let g = near.min(by: { abs($0.alongMeters - steps[i].alongMeters) < abs($1.alongMeters - steps[i].alongMeters) }),
                  let n = g.exit, n != steps[i].exit else { continue }
            steps[i].exit = n
            steps[i].instruction = OSRM.instruction(type: "roundabout", modifier: nil, road: steps[i].road, exit: n, mode: .drive)
            // The way off says the same number.
            if i + 1 < steps.count, steps[i + 1].leavesRoundabout { steps[i + 1].exit = n }
        }
    }

    public static func addGoogleLaneHints(_ steps: inout [Maneuver], from google: [Maneuver]) {
        for i in steps.indices where !steps[i].silent && steps[i].lanes.isEmpty && steps[i].laneHint == nil {
            let near = google.filter { $0.laneHint != nil && abs($0.alongMeters - steps[i].alongMeters) < 150 }
            steps[i].laneHint = near.min { abs($0.alongMeters - steps[i].alongMeters) < abs($1.alongMeters - steps[i].alongMeters) }?.laneHint
        }
    }
}

/** Google words its steps the American way even in Britain: "Take the ramp" is a slip road there. */
public enum British {
    public static func words(_ text: String) -> String {
        text.replacingOccurrences(of: #"\b(the|a) ramp\b"#, with: "$1 slip road", options: .regularExpression)
            .replacingOccurrences(of: #"\bramp\b"#, with: "slip road", options: .regularExpression)
            .replacingOccurrences(of: #"\bparking lot\b"#, with: "car park", options: .regularExpression)
            .replacingOccurrences(of: #"\bparking garage\b"#, with: "multi-storey car park", options: .regularExpression)
            .replacingOccurrences(of: #"\bfreeway\b"#, with: "motorway", options: .regularExpression)
    }
}
