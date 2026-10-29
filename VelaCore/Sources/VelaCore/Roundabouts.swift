import Foundation

/**
 * The real layout of the roundabouts on a route, from OpenStreetMap: the circle, every road that
 * meets it, which of those you can leave by, and the one the route takes. Drawn in the driving
 * banner so "6th exit" comes with a picture of all six.
 */
public enum Roundabouts {
    struct Way {
        var id: Int64
        var nodes: [Int64]
        var points: [LatLng]
        var tags: [String: String]
        var isRing: Bool { ["roundabout", "circular"].contains(tags["junction"] ?? "") }
    }

    /** A road meeting the circle: where (compass bearing from the middle), and which ways traffic can go. */
    struct Arm {
        var angle: Double
        var canExit: Bool
        var canEnter: Bool
        var name: String?
    }

    /** Fills in [Maneuver.roundabout] on every roundabout of [route] that OpenStreetMap answers for. */
    public static func apply(to route: Route) async -> Route? {
        let spots = route.maneuvers.filter { $0.type == .roundabout && !$0.leavesRoundabout }.map(\.location)
        guard !spots.isEmpty, let data = await fetch(spots) else { return nil }
        var r = route
        let ways = parse(data)
        guard !ways.isEmpty else { return nil }
        let clockwise = Geo.drivesOnLeft(spots[0])
        let cum = Geo.cumulative(route.polyline)
        var changed = false
        for i in r.maneuvers.indices where r.maneuvers[i].type == .roundabout {
            let m = r.maneuvers[i]
            if m.leavesRoundabout {
                // The way off: the same picture as the way on.
                if i > 0, r.maneuvers[i - 1].type == .roundabout, let prev = r.maneuvers[i - 1].roundabout {
                    r.maneuvers[i].roundabout = prev
                    r.maneuvers[i].exit = r.maneuvers[i].exit ?? r.maneuvers[i - 1].exit
                }
                continue
            }
            // Where the route comes off the circle, from the circle itself; the router's step otherwise.
            let leave = leaving(ways, entry: m.location, line: route.polyline, cumulative: cum, along: m.alongMeters) ?? wayOff(r.maneuvers, i)
            let out = exitAngle(route.polyline, cumulative: cum, along: m.alongMeters, leaving: leave)
            // The map's picture only if it counts the exits the way the spoken "Nth exit" does; on
            // 2026-10-25's Hampshire drives that held for 17 of 24, and the rest keep the router's sketch.
            if let s = shape(ways, entry: m.location, line: route.polyline, cumulative: cum, along: m.alongMeters,
                             clockwise: clockwise, exitNumber: m.exit), m.exit == nil || s.taken + 1 == m.exit {
                r.maneuvers[i].roundabout = out.map { aim(s, at: $0) } ?? s
                changed = true
            } else if let out, let s = m.roundabout, s.exits.indices.contains(s.taken), angleGap(s.exits[s.taken], out) > 1 {
                // The router's sketch, pointed at the way out found from the circle.
                r.maneuvers[i].roundabout = angleGap(s.exits[s.taken], out) < 50 ? aim(s, at: out)
                    : spread(to: out, exit: m.exit ?? 1, clockwise: clockwise)
                changed = true
            }
            // How many lanes the road in has at the give-way line, for the lane advice.
            if r.maneuvers[i].roundabout != nil, let e = entryLanes(ways, line: route.polyline, cumulative: cum, along: m.alongMeters) {
                r.maneuvers[i].roundabout?.entryLanes = e.count
                r.maneuvers[i].roundabout?.entryArrows = e.arrows
                changed = true
            }
        }
        return changed ? r : nil
    }

    /**
     * Makes every roundabout's picture point the way the route really leaves it. The router's sketch
     * needs at least one exit passed to place the circle, so a 1st exit had none and was drawn
     * spread evenly round, which put a straight-on 1st exit off to the left (Chestnut Avenue,
     * Eastleigh, 2026-10-27). The route line itself says which way it goes out, so a picture whose
     * exit doesn't agree with it is redrawn from the line, and one that roughly agrees is turned
     * to match it.
     */
    public static func settle(_ route: Route) -> Route {
        var r = route
        let cum = Geo.cumulative(route.polyline)
        for i in r.maneuvers.indices where r.maneuvers[i].type == .roundabout {
            let m = r.maneuvers[i]
            if m.leavesRoundabout {
                if i > 0, r.maneuvers[i - 1].type == .roundabout { r.maneuvers[i].roundabout = r.maneuvers[i - 1].roundabout }
                continue
            }
            guard let out = exitAngle(route.polyline, cumulative: cum, along: m.alongMeters, leaving: wayOff(r.maneuvers, i)) else { continue }
            if let s = m.roundabout, s.exits.indices.contains(s.taken), angleGap(s.exits[s.taken], out) < 50 {
                r.maneuvers[i].roundabout = aim(s, at: out)
            } else {
                r.maneuvers[i].roundabout = spread(to: out, exit: m.exit ?? 1, clockwise: Geo.drivesOnLeft(m.location))
            }
        }
        return r
    }

    /**
     * [shape] with your exit turned to point at [out], the way the road really goes. The map puts
     * each road where it touches the circle, which on a big roundabout can be well off the way it
     * heads: a 1st exit that runs straight on touches the ring near the bottom left, and the
     * picture showed a sharp left (2026-10-27 audit: about 1 in 6 of 63 Hampshire, Wales, London
     * and Milton Keynes roundabouts, 50 to 100 degrees out). The other roads move round with it, in the same
     * order, so the count still matches.
     */
    static func aim(_ shape: RoundaboutShape, at out: Double) -> RoundaboutShape {
        guard shape.exits.indices.contains(shape.taken) else { return shape }
        let cw = shape.clockwise
        // How far round from the way in; the same road back out is a full lap.
        func travel(_ a: Double) -> Double {
            let t = norm(cw ? a - 180 : 180 - a)
            return t < 15 ? t + 360 : t
        }
        func angle(_ t: Double) -> Double { norm(cw ? 180 + t : 180 - t) }
        let from = travel(shape.exits[shape.taken])
        guard from < 345 else { return shape }
        let to = min(max(travel(out), 10), 350)
        // Stretch the bit of circle up to your exit, and squeeze the rest, or the other way round.
        func move(_ a: Double) -> Double {
            let t = travel(a)
            return angle(t <= from ? t * to / from : to + (t - from) * (375 - to) / (375 - from))
        }
        var s = shape
        s.exits = shape.exits.indices.map { $0 == shape.taken ? angle(to) : move(shape.exits[$0]) }
        s.entriesOnly = shape.entriesOnly.map(move)
        return s
    }

    /**
     * Where [line] comes off the roundabout it enters at [along]: the first point more than 20 m
     * from every part of the circle (the mapped ring ways at [entry] and any joined to them).
     */
    static func leaving(_ ways: [Way], entry: LatLng, line: [LatLng], cumulative cum: [Double], along: Double) -> Double? {
        let rings = ways.filter(\.isRing)
        guard let first = rings.min(by: { distance(entry, $0) < distance(entry, $1) }), distance(entry, first) < 40 else { return nil }
        var ring = [first]
        var nodes = Set(first.nodes)
        var grew = true
        while grew {
            grew = false
            for w in rings where !ring.contains(where: { $0.id == w.id }) && w.nodes.contains(where: nodes.contains) {
                ring.append(w)
                nodes.formUnion(w.nodes)
                grew = true
            }
        }
        let total = cum.last ?? 0
        var d = along + 10
        while d < min(total, along + 2500) {
            let p = Geo.point(along: line, meters: d, cumulative: cum)
            if ring.allSatisfy({ distance(p, $0) > 20 }) { return max(along + 10, d - 15) }
            d += 4
        }
        return nil
    }

    /** Where the route comes off the roundabout entered at step [i]: the "exit roundabout" step after it. */
    public static func wayOff(_ steps: [Maneuver], _ i: Int) -> Double? {
        guard i + 1 < steps.count, steps[i + 1].leavesRoundabout else { return nil }
        return steps[i + 1].alongMeters
    }

    /**
     * The lanes of the road the route comes in on, just before the roundabout at [along]: the
     * OpenStreetMap way under the line 15 m back, its `lanes` (or the ones going this way on a
     * two-way road). Nil when the map doesn't say.
     */
    static func entryLanes(_ ways: [Way], line: [LatLng], cumulative cum: [Double], along: Double) -> (count: Int, arrows: [String]?)? {
        guard along > 30 else { return nil }
        let p = Geo.point(along: line, meters: along - 15, cumulative: cum)
        let back = Geo.point(along: line, meters: along - 30, cumulative: cum)
        let roads = ways.filter { !$0.isRing && $0.tags["highway"] != nil }
        guard let w = roads.min(by: { distance(p, $0) < distance(p, $1) }), distance(p, w) < 10 else { return nil }
        func count(_ k: String) -> Int? { w.tags[k].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        let n: Int?, turns: String?
        if onewayDirection(w.tags) != 0 {
            n = count("lanes")
            turns = w.tags["turn:lanes"]
        } else {
            // Along the way's own order or against it.
            let forward = Geo.project(p, on: w.points).along > Geo.project(back, on: w.points).along
            n = count(forward ? "lanes:forward" : "lanes:backward") ?? count("lanes").map { max(1, $0 / 2) }
            turns = w.tags[forward ? "turn:lanes:forward" : "turn:lanes:backward"]
        }
        // The arrows painted on each lane, left to right, when mapped for every lane ("left|through|through;right").
        let arrows = turns.map { $0.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
        guard let n, (1...6).contains(n) else { return nil }
        return (n, arrows?.count == n && arrows!.contains { !$0.isEmpty && $0 != "none" } ? arrows : nil)
    }

    /** [exit] exits, the last one at [out] and the ones before it spaced evenly on the way round. */
    static func spread(to out: Double, exit: Int, clockwise: Bool) -> RoundaboutShape {
        let n = max(exit, 1)
        let t = norm(clockwise ? out - 180 : 180 - out)
        let travel = t < 15 ? t + 360 : t
        let exits = (1...n).map { k -> Double in
            let d = travel * Double(k) / Double(n)
            return norm(clockwise ? 180 + d : 180 - d)
        }
        return RoundaboutShape(exits: exits, taken: n - 1, clockwise: clockwise, complete: false)
    }

    /**
     * Which way [line] leaves the roundabout it reaches at [along], in the picture's terms: degrees
     * clockwise from straight ahead, so 0 is straight on, 90 right, 270 left and 180 back the way
     * it came. The way out is the first 60 m of road from [leaving], where the route comes off the
     * circle, when that's known, or else the first 40 m of steady road after it. On a big roundabout the circle itself is nearly
     * straight for 40 m, and reading it from just after the way in took the ring for the way out
     * (Rownhams, M27 junction 3, 2026-10-28: the M27 east exit drawn as straight on).
     */
    public static func exitAngle(_ line: [LatLng], cumulative cum: [Double], along: Double, leaving: Double? = nil) -> Double? {
        let total = cum.last ?? 0
        func heading(_ a: Double, _ b: Double) -> Double? {
            let p = Geo.point(along: line, meters: max(0, a), cumulative: cum), q = Geo.point(along: line, meters: min(total, b), cumulative: cum)
            return p.distance(to: q) > 3 ? Geo.bearing(p, q) : nil
        }
        guard let into = heading(along - 40, along - 6) else { return nil }
        // Known where it comes off: the first 60 m of road from there, the way it looks at the exit
        // (a slip road that bends away later still leaves the circle the way it starts).
        if let off = leaving, off > along, off < along + 1500, off + 30 < total, let h = heading(off + 5, min(total, off + 65)) {
            return norm(h - into)
        }
        let start = along + 6
        // Otherwise only road straighter than any ring: every 10 m of a 40 m stretch within 5 degrees
        // of the whole (a 230 m circle), so a stretch that cuts the corner where the road leaves the
        // ring doesn't count.
        let steady = 5.0
        var d = start
        while d + 40 <= min(total, start + 1000) {
            if let h = heading(d, d + 40), stride(from: d, to: d + 40, by: 10).allSatisfy({ a in heading(a, a + 10).map { angleGap($0, h) < steady } ?? false }) {
                return norm(h - into)
            }
            d += 4
        }
        // The route ends just after it: the last bit of road there is. A road that never settles: its first 60 m.
        if total < start + 60 { return heading(along + 10, total).map { norm($0 - into) } }
        return heading(start, start + 60).map { norm($0 - into) }
    }

    /**
     * Mini-roundabouts on the route, from OpenStreetMap: a painted circle mapped as a single point
     * (highway=mini_roundabout). Neither the open router nor Google says anything when the route
     * goes over one, so the banner skipped them (Normandy Way, Marchwood, 2026-10-27). Each one the
     * route crosses becomes a roundabout step with its exit number and picture; a turn the router
     * already gives there ("Turn left onto ...") becomes "At the roundabout, take the 1st exit".
     * Nil when there are none, or OpenStreetMap didn't answer.
     */
    public static func addMinis(to route: Route) async -> Route? {
        guard route.mode == .drive, route.polyline.count >= 2 else { return nil }
        // A point every 40 m or so is close enough for "within 15 m of the line", and keeps a long drive's query small.
        var line = [route.polyline[0]]
        for p in route.polyline.dropFirst() where line[line.count - 1].distance(to: p) >= 40 { line.append(p) }
        line.append(route.polyline[route.polyline.count - 1])
        let coords = line.prefix(3000).map { String(format: "%.5f,%.5f", $0.lat, $0.lng) }.joined(separator: ",")
        let q = "[out:json][timeout:25];node[\"highway\"=\"mini_roundabout\"](around:15," + coords + ")->.m;.m out;" +
            "way(bn.m)[\"highway\"][\"highway\"!~\"^(footway|cycleway|path|pedestrian|steps|bridleway|corridor|construction|proposed|platform)$\"];out geom;"
        guard let data = await Overpass.query(q) else { return nil }
        let minis = parseNodes(data)
        guard !minis.isEmpty else { return nil }
        return withMinis(route, minis: minis, ways: parse(data))
    }

    /** The mini-roundabout points in an Overpass answer. */
    static func parseNodes(_ data: Data) -> [(id: Int64, at: LatLng)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return [] }
        return elements.compactMap { e in
            guard e["type"] as? String == "node", let id = (e["id"] as? NSNumber)?.int64Value,
                  let lat = e["lat"] as? Double, let lon = e["lon"] as? Double else { return nil }
            return (id, LatLng(lat, lon))
        }
    }

    static func withMinis(_ route: Route, minis: [(id: Int64, at: LatLng)], ways: [Way]) -> Route? {
        var r = route
        let cum = Geo.cumulative(route.polyline)
        let total = cum.last ?? 0
        let clockwise = Geo.drivesOnLeft(route.polyline[0])
        var changed = false
        for mini in minis {
            let p = Geo.project(mini.at, on: route.polyline, cumulative: cum)
            guard p.offset < 15, p.along > 20, p.along < total - 30,
                  let s = miniShape(mini.id, at: mini.at, ways: ways, line: route.polyline, cumulative: cum, along: p.along, clockwise: clockwise)
            else { continue }
            let n = s.shape.taken + 1
            let near = r.maneuvers.indices.filter { abs(r.maneuvers[$0].alongMeters - p.along) < 30 && !r.maneuvers[$0].silent }
            // The router already has a roundabout here.
            if near.contains(where: { r.maneuvers[$0].type == .roundabout }) { continue }
            if let i = near.first(where: { ![.depart, .arrive].contains(r.maneuvers[$0].type) }) {
                // A turn at the mini-roundabout: said the roundabout way, onto the same road.
                let road = r.maneuvers[i].road
                r.maneuvers[i].type = .roundabout
                r.maneuvers[i].exit = n
                r.maneuvers[i].roundabout = s.shape
                r.maneuvers[i].lanes = []
                r.maneuvers[i].laneHint = nil
                r.maneuvers[i].instruction = OSRM.instruction(type: "roundabout", modifier: nil, road: road, exit: n, mode: .drive)
            } else {
                // Over it with no step: a new one, with the road it leads onto when that's a different road.
                let k = r.maneuvers.lastIndex { $0.alongMeters <= p.along } ?? 0
                let current = r.maneuvers[...k].last { $0.road != nil }?.road
                let onto = s.road.flatMap { $0 == current ? nil : $0 }
                var m = Maneuver(type: .roundabout, instruction: OSRM.instruction(type: "roundabout", modifier: nil, road: onto, exit: n, mode: .drive),
                                 location: Geo.point(along: route.polyline, meters: p.along, cumulative: cum), alongMeters: p.along,
                                 distanceMeters: 0, road: s.road ?? current, exit: n, roundabout: s.shape)
                if k + 1 < r.maneuvers.count { m.distanceMeters = r.maneuvers[k + 1].alongMeters - p.along }
                r.maneuvers[k].distanceMeters = p.along - r.maneuvers[k].alongMeters
                r.maneuvers.insert(m, at: k + 1)
            }
            changed = true
        }
        return changed ? r : nil
    }

    /** The picture of mini-roundabout [id]: every road meeting at the point, the way in at the bottom. */
    static func miniShape(_ id: Int64, at center: LatLng, ways: [Way], line: [LatLng], cumulative cum: [Double], along: Double,
                          clockwise: Bool) -> (shape: RoundaboutShape, road: String?)? {
        var arms: [(angle: Double, canExit: Bool, name: String?)] = []
        for w in ways {
            let oneway = onewayDirection(w.tags)
            for (i, n) in w.nodes.enumerated() where n == id {
                for dir in [1, -1] {
                    // Where the road heads, about 15 m out (the next node can sit right by the circle).
                    var j = i + dir
                    while j >= 0, j < w.points.count, w.points[j].distance(to: center) < 15, j + dir >= 0, j + dir < w.points.count { j += dir }
                    guard j >= 0, j < w.points.count, w.points[j].distance(to: center) > 2 else { continue }
                    arms.append((Geo.bearing(center, w.points[j]), oneway == 0 || oneway == dir, w.tags["name"] ?? w.tags["ref"]))
                }
            }
        }
        guard arms.count >= 3 else { return nil }
        let back = Geo.point(along: line, meters: max(0, along - 20), cumulative: cum)
        let ahead = Geo.point(along: line, meters: along + 20, cumulative: cum)
        guard back.distance(to: center) > 5, ahead.distance(to: center) > 5 else { return nil }
        let inAngle = Geo.bearing(center, back), outAngle = Geo.bearing(center, ahead)
        guard let entry = arms.indices.min(by: { angleGap(arms[$0].angle, inAngle) < angleGap(arms[$1].angle, inAngle) }),
              angleGap(arms[entry].angle, inAngle) < 45 else { return nil }
        func rel(_ a: Double) -> Double { norm(a - arms[entry].angle + 180) }
        func travel(_ r: Double) -> Double {
            let t = norm(clockwise ? r - 180 : 180 - r)
            return t < 15 ? t + 360 : t
        }
        let exits = arms.indices.filter { $0 != entry && arms[$0].canExit }.sorted { travel(rel(arms[$0].angle)) < travel(rel(arms[$1].angle)) }
        guard let taken = exits.indices.min(by: { angleGap(arms[exits[$0]].angle, outAngle) < angleGap(arms[exits[$1]].angle, outAngle) }),
              angleGap(arms[exits[taken]].angle, outAngle) < 45 else { return nil }
        let inOnly = arms.indices.filter { $0 != entry && !arms[$0].canExit }.map { rel(arms[$0].angle) }
        var shape = RoundaboutShape(exits: exits.map { rel(arms[$0].angle) }, taken: taken, entriesOnly: inOnly, clockwise: clockwise, complete: true)
        shape.mini = true
        return (shape, arms[exits[taken]].name)
    }

    static func fetch(_ spots: [LatLng]) async -> Data? {
        // At most 40 roundabouts per drive; a long one rarely has more in the next stretch that matters.
        let around = spots.prefix(40).map {
            String(format: "way[\"junction\"~\"^(roundabout|circular)$\"](around:35,%.6f,%.6f);", $0.lat, $0.lng)
        }.joined()
        let q = "[out:json][timeout:25];(" + around + ")->.r;.r out geom;node(w.r)->.n;" +
            "way(bn.n)[\"highway\"][\"highway\"!~\"^(footway|cycleway|path|pedestrian|steps|bridleway|corridor|construction|proposed|platform|bus_guideway|escape|raceway)$\"];out geom;"
        return await Overpass.query(q)
    }

    static func parse(_ data: Data) -> [Way] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return [] }
        var seen = Set<Int64>()
        var out: [Way] = []
        for e in elements where e["type"] as? String == "way" {
            guard let id = (e["id"] as? NSNumber)?.int64Value, seen.insert(id).inserted,
                  let nodes = (e["nodes"] as? [NSNumber])?.map(\.int64Value),
                  let geom = e["geometry"] as? [[String: Any]], geom.count == nodes.count, nodes.count >= 2 else { continue }
            let pts = geom.compactMap { g -> LatLng? in
                guard let lat = g["lat"] as? Double, let lon = g["lon"] as? Double else { return nil }
                return LatLng(lat, lon)
            }
            guard pts.count == nodes.count else { continue }
            out.append(Way(id: id, nodes: nodes, points: pts, tags: e["tags"] as? [String: String] ?? [:]))
        }
        return out
    }

    /**
     * The roundabout entered at [entry]: the ring ways near it and every road touching them. The
     * exit taken is where [line] leaves the circle after [along].
     */
    static func shape(_ ways: [Way], entry: LatLng, line: [LatLng], cumulative cum: [Double], along: Double,
                      clockwise: Bool, exitNumber: Int?) -> RoundaboutShape? {
        let rings = ways.filter(\.isRing)
        // The ring way(s) passing the entry, and any joined to them.
        guard let first = rings.min(by: { distance(entry, $0) < distance(entry, $1) }), distance(entry, first) < 40 else { return nil }
        var ring = [first]
        var nodes = Set(first.nodes)
        var grew = true
        while grew {
            grew = false
            for w in rings where !ring.contains(where: { $0.id == w.id }) && w.nodes.contains(where: nodes.contains) {
                ring.append(w)
                nodes.formUnion(w.nodes)
                grew = true
            }
        }
        // The middle: the centroid of the circle's outline, by length, so bunched-up nodes don't pull it.
        var sx = 0.0, sy = 0.0, total = 0.0
        for w in ring {
            for k in 1..<w.points.count {
                let a = w.points[k - 1], b = w.points[k]
                let len = a.distance(to: b)
                sx += (a.lat + b.lat) / 2 * len
                sy += (a.lng + b.lng) / 2 * len
                total += len
            }
        }
        guard total > 10 else { return nil }
        let center = LatLng(sx / total, sy / total)
        let radius = ring.flatMap(\.points).map { $0.distance(to: center) }.reduce(0, +) / Double(ring.flatMap(\.points).count)
        guard radius > 3, radius < 250 else { return nil }

        // Every road meeting the circle, both ways out from where it touches.
        var arms: [Arm] = []
        for w in ways where !w.isRing {
            if let access = w.tags["access"] ?? w.tags["motor_vehicle"], ["no", "private"].contains(access) { continue }
            let oneway = onewayDirection(w.tags)
            for (i, n) in w.nodes.enumerated() where nodes.contains(n) {
                let p = w.points[i]
                // Away from the ring along the way's own order (forward) or against it.
                for dir in [1, -1] {
                    let j = i + dir
                    guard j >= 0, j < w.nodes.count, !nodes.contains(w.nodes[j]) else { continue }
                    // Traffic leaves the circle along this arm when it may flow in that direction.
                    let leaves = oneway == 0 || oneway == dir
                    let comes = oneway == 0 || oneway == -dir
                    arms.append(Arm(angle: Geo.bearing(center, p), canExit: leaves, canEnter: comes, name: w.tags["ref"] ?? w.tags["name"]))
                }
            }
        }
        arms = merge(arms)
        guard !arms.isEmpty else { return nil }

        // Turn everything so the way in sits at the bottom (180 degrees).
        let entryAngle = Geo.bearing(center, entry)
        func rel(_ a: Double) -> Double { norm(a - entryAngle + 180) }
        // How far round from the way in, the way traffic goes; the same road back out is a full lap.
        func travel(_ r: Double) -> Double {
            let t = norm(clockwise ? r - 180 : 180 - r)
            return t < 15 ? t + 360 : t
        }
        let exits = arms.filter(\.canExit).map { rel($0.angle) }.sorted { travel($0) < travel($1) }
        guard !exits.isEmpty else { return nil }
        // Roads that only come in, except the one you're on.
        let inOnly = arms.filter { !$0.canExit && angleGap(rel($0.angle), 180) > 25 }.map { rel($0.angle) }

        // Where the route leaves: its first point after the entry clearly outside the circle.
        guard let outPoint = leavingPoint(line, cumulative: cum, after: along, center: center, radius: radius) else { return nil }
        let outAngle = rel(Geo.bearing(center, outPoint))
        guard let taken = exits.indices.min(by: { angleGap(exits[$0], outAngle) < angleGap(exits[$1], outAngle) }),
              angleGap(exits[taken], outAngle) < 50 else { return nil }
        return RoundaboutShape(exits: exits, taken: taken, entriesOnly: inOnly, clockwise: clockwise, complete: true)
    }

    /** 1 when traffic may only go along the way's node order, -1 only against it, 0 both ways. */
    static func onewayDirection(_ tags: [String: String]) -> Int {
        switch tags["oneway"] ?? "" {
        case "yes", "true", "1": return 1
        case "-1", "reverse": return -1
        default: return tags["highway"] == "motorway" ? 1 : 0
        }
    }

    /**
     * A dual carriageway meets the circle twice, once going in and once coming out, close
     * together: that's one road in the picture.
     */
    static func merge(_ arms: [Arm]) -> [Arm] {
        var list = arms.sorted { $0.angle < $1.angle }
        var i = 0
        while list.count > 1 && i < list.count {
            let j = (i + 1) % list.count
            let a = list[i], b = list[j]
            let pair = (a.canExit && !a.canEnter && b.canEnter && !b.canExit) || (b.canExit && !b.canEnter && a.canEnter && !a.canExit)
            let sameRoad = a.name == nil || b.name == nil || a.name == b.name
            if i != j, pair, sameRoad, angleGap(a.angle, b.angle) < 40 {
                let mid = norm(a.angle + signedGap(a.angle, b.angle) / 2)
                list[i] = Arm(angle: mid, canExit: true, canEnter: true, name: a.name ?? b.name)
                list.remove(at: j)
                if j < i { i -= 1 }
            } else {
                i += 1
            }
        }
        return list
    }

    static func leavingPoint(_ line: [LatLng], cumulative cum: [Double], after along: Double, center: LatLng, radius: Double) -> LatLng? {
        var m = along + 5
        let end = min((cum.last ?? 0), along + radius * 8 + 200)
        while m <= end {
            let p = Geo.point(along: line, meters: m, cumulative: cum)
            if p.distance(to: center) > radius + max(12, radius * 0.4) { return p }
            m += 4
        }
        return nil
    }

    static func distance(_ p: LatLng, _ w: Way) -> Double {
        Geo.project(p, on: w.points).offset
    }

    static func norm(_ a: Double) -> Double {
        (a.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    public static func angleGap(_ a: Double, _ b: Double) -> Double {
        abs(signedGap(a, b))
    }

    /** From a to b the short way round, -180 to 180. */
    static func signedGap(_ a: Double, _ b: Double) -> Double {
        var d = norm(b - a)
        if d > 180 { d -= 360 }
        return d
    }
}
