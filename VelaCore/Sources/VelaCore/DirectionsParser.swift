import Foundation

/**
 * Google `/maps/preview/directions` request and response (port of Vela's DirectionsPb and
 * DirectionsParser). Routes are at `root[0][1]`; route geometry at `root[0][7][i]` as E7 deltas;
 * per route summary at `[0]`: distance `[2][0]`, typical seconds `[3][0]`, traffic seconds
 * `[10][0][0]`, summary text `[1]`; congestion spans at `route[3][5][0]`; steps are
 * `<step maneuver='..' meters='..'>` markup strings anywhere under the route.
 */
enum DirectionsPb {
    static let template = """
        !1m4!3m2!3d{OLAT}!4d{OLNG}!6e2!1m4!3m2!3d{DLAT}!4d{DLNG}!6e2!3m12!1m3!1d24960.741896132306\
        !2d-121.7527808!3d38.554674999999996!2m3!1f0.0!2f0.0!3f0.0!3m2!1i1024!2i768!4f13.1!6m56!1m\
        5!18b1!30b1!31m1!1b1!34e1!2m4!5m1!6e2!20e3!39b1!6m27!32i1!49b1!63m0!66b1!85b1!114b1!149b1!\
        206b1!209b1!212b1!216b1!222b1!223b1!232b1!234b1!235b1!244b1!246b1!250b1!253b1!260b1!266b1!\
        270b1!273b1!279b1!281b1!291m0!10b1!12b1!13b1!14b1!16b1!17m1!3e1!20m5!1e{MODE}!2e3!5e2!6b1!\
        14b1!46m1!1b0!96b1!99b1!15i10142!20m28!1m6!1m2!1i0!2i0!2m2!1i530!2i768!1m6!1m2!1i974!2i0!2\
        m2!1i1024!2i768!1m6!1m2!1i0!2i0!2m2!1i1024!2i20!1m6!1m2!1i0!2i748!2m2!1i1024!2i768!27b1!40\
        i783!47m2!8b1!10e2
        """

    static func build(origin: LatLng, destination: LatLng, mode: TravelMode,
                      avoidHighways: Bool = false, avoidTolls: Bool = false, waypoints: [LatLng] = []) -> String {
        var pb = template
        // Stops: one more top-level waypoint group each, between origin and destination (Vela's
        // withWaypoints). Google answers a single route through them.
        if !waypoints.isEmpty, let r = pb.range(of: "!1m4!3m2!3d{DLAT}!4d{DLNG}!6e2") {
            pb.insert(contentsOf: waypoints.map { "!1m4!3m2!3d\($0.lat)!4d\($0.lng)!6e2" }.joined(), at: r.lowerBound)
        }
        let all = [origin, destination] + waypoints
        // Center the request's map on the trip, the way a browser's map sits around it.
        if let r = pb.range(of: #"!3m12!1m3!1d[0-9.]+!2d-?[0-9.]+!3d-?[0-9.]+"#, options: .regularExpression) {
            let s = all.map(\.lat).min()!, n = all.map(\.lat).max()!
            let w = all.map(\.lng).min()!, e = all.map(\.lng).max()!
            let lat = (s + n) / 2, lng = (w + e) / 2
            let span = max((n - s) * 111_320, (e - w) * 111_320 * cos(lat * .pi / 180))
            pb.replaceSubrange(r, with: "!3m12!1m3!1d\(max(span * 1.35, 1500))!2d\(lng)!3d\(lat)")
        }
        if mode == .drive, avoidHighways || avoidTolls,
           let r = pb.range(of: "!6m56!1m5!18b1!30b1!31m1!1b1!34e1!2m4") {
            let flags = (avoidHighways ? "!1b1" : "") + (avoidTolls ? "!2b1" : "")
            let added = (avoidHighways ? 1 : 0) + (avoidTolls ? 1 : 0)
            pb.replaceSubrange(r, with: "!6m\(56 + added)!1m5!18b1!30b1!31m1!1b1!34e1!2m\(4 + added)\(flags)")
        }
        return pb
            .replacingOccurrences(of: "{OLAT}", with: String(origin.lat))
            .replacingOccurrences(of: "{OLNG}", with: String(origin.lng))
            .replacingOccurrences(of: "{DLAT}", with: String(destination.lat))
            .replacingOccurrences(of: "{DLNG}", with: String(destination.lng))
            .replacingOccurrences(of: "{MODE}", with: String(mode.rawValue))
    }
}

enum DirectionsParser {
    static func parse(root: Any, mode: TravelMode) -> [Route] {
        guard let routes = arr(at(root, 0, 1)) else { return [] }
        let geoms = arr(at(root, 0, 7))
        return routes.enumerated().compactMap { i, r in
            parseRoute(r, geometry: decodeGeometry(geoms.flatMap { i < $0.count ? $0[i] : nil }), mode: mode)
        }
    }

    private static func parseRoute(_ route: Any, geometry: [LatLng]?, mode: TravelMode) -> Route? {
        guard let summary = at(route, 0),
              let distance = dbl(at(summary, 2, 0)),
              let typical = dbl(at(summary, 3, 0)) else { return nil }
        let traffic = dbl(at(summary, 10, 0, 0))
        let start = coord(at(summary, 7, 3, 2)), end = coord(at(summary, 7, 3, 3))
        let line = (geometry?.count ?? 0) >= 2 ? geometry! : [start, end].compactMap { $0 }
        guard line.count >= 2 else { return nil }
        let spans: [TrafficSpan] = (arr(at(route, 3, 5, 0)) ?? []).compactMap { s in
            guard let level = int(at(s, 0)), let st = dbl(at(s, 1)), let len = dbl(at(s, 2)), len > 0, level >= 1 else { return nil }
            return TrafficSpan(level: level, startMeters: st, lengthMeters: len)
        }.sorted { $0.startMeters < $1.startMeters }
        var steps: [Maneuver] = []
        collectSteps(route, into: &steps)
        var r = Route(mode: mode, polyline: line, distanceMeters: distance, typicalSeconds: typical,
                      trafficSeconds: traffic, summary: str(at(summary, 1)),
                      maneuvers: place(steps, on: line), trafficSpans: spans, source: "google")
        let stepTotal = steps.reduce(0) { $0 + ($1.type == .arrive ? 0 : $1.distanceMeters) }
        r.stepsComplete = stepTotal >= Geo.length(line) * 0.85
        return r
    }

    private static func coord(_ n: Any?) -> LatLng? {
        guard let lat = dbl(at(n, 2)), let lng = dbl(at(n, 3)) else { return nil }
        return LatLng(lat, lng)
    }

    /** `[0]` latitude deltas, `[1]` longitude deltas, E7, the first absolute. */
    static func decodeGeometry(_ node: Any?) -> [LatLng]? {
        guard let lat = arr(at(node, 0)), let lng = arr(at(node, 1)), lat.count == lng.count, lat.count >= 2 else { return nil }
        var la = 0.0, ln = 0.0
        return lat.indices.map { i in
            la += dbl(lat[i]) ?? 0
            ln += dbl(lng[i]) ?? 0
            return LatLng(la / 1e7, ln / 1e7)
        }
    }

    static func collectSteps(_ n: Any, into out: inout [Maneuver]) {
        if let a = n as? [Any] {
            // A step entry is [step, _, [icon, class], ...].
            if let node = a.first as? [Any], let folded = foldedStep(node, icon: str(at(a, 2, 1))) {
                out.append(folded)
                return
            }
            // A step's own markup with its icon beside it: a slip road with no side in the markup
            // takes the icon's ("dir-tt-ramp-left" for "Exit at junction 10").
            if let node = a.first as? [Any], let s = str(at(node, 1)), s.contains("<step "), node.count > 2 {
                var m = parseStep(s)
                if m.sideUnknown, let icon = str(at(a, 2, 1)) {
                    if icon.contains("-left") { m.type = .rampLeft; m.sideUnknown = false }
                    else if icon.contains("-right") { m.type = .rampRight; m.sideUnknown = false }
                }
                out.append(m)
                return
            }
            for e in a { collectSteps(e, into: &out) }
        } else if let s = n as? String, s.contains("<step ") {
            out.append(parseStep(s))
        }
    }

    /**
     * A step Google sends with no `<step>` text: the long motorway stretch inside a folded group
     * ("Merge onto M27", 12.5 km). Its length is `[2][0]`, its words are pieces like
     * `[[2,["Merge onto "]],[2,["M27",1]]]`, its time `[3]`, and its kind is in the entry's icon class
     * ("dir-tt dir-tt-merge"). Left out, the turns after it are counted back to the wrong places.
     */
    static func foldedStep(_ a: [Any], icon: String?) -> Maneuver? {
        guard a.count > 3, int(at(a, 0)) == 0, let markup = a[1] as? String, markup.isEmpty,
              let meters = dbl(at(a, 2, 0)), str(at(a, 2, 1)) != nil,
              dbl(at(a, 3, 0)) != nil, str(at(a, 3, 1)) != nil else { return nil }
        var text = "", road: String?
        for e in a {
            guard let pieces = e as? [Any], !pieces.isEmpty,
                  pieces.allSatisfy({ int(at($0, 0)) != nil && str(at($0, 1, 0)) != nil }) else { continue }
            for p in pieces {
                let t = str(at(p, 1, 0)) ?? ""
                // Bold pieces are road names, and also the turn's direction ("Keep <b>right</b>").
                if int(at(p, 1, 1)) == 1, road == nil,
                   t.range(of: #"^\s*((slight|sharp)\s+)?(left|right)\s*$"#, options: [.regularExpression, .caseInsensitive]) == nil { road = t }
                text += t
            }
            break
        }
        let kind = (icon ?? "").components(separatedBy: " ").last { $0.hasPrefix("dir-tt-") }.map { String($0.dropFirst(7)) } ?? ""
        let token = kind.uppercased().replacingOccurrences(of: "-", with: "_")
        let side = kind.contains("left") ? "LEFT" : (kind.contains("right") ? "RIGHT" : nil)
        let severity = kind.contains("slight") ? "SLIGHT" : (kind.contains("sharp") ? "SHARP" : nil)
        var m = parseStep("<step meters='\(Int(meters))'>\(text)</step>")
        m.type = mapType(token.isEmpty ? nil : token, side: side, severity: severity)
        m.road = road
        // No words at all: say what the icon shows rather than "Continue" at a turn.
        if text.trimmingCharacters(in: .whitespaces).isEmpty { m.instruction = phrase(m.type) }
        return m
    }

    static func phrase(_ t: ManeuverType) -> String {
        switch t {
        case .turnLeft: return "Turn left"
        case .turnRight: return "Turn right"
        case .slightLeft: return "Slight left"
        case .slightRight: return "Slight right"
        case .sharpLeft: return "Sharp left"
        case .sharpRight: return "Sharp right"
        case .uturn: return "Make a U-turn"
        case .merge: return "Merge"
        case .rampLeft: return "Take the slip road on the left"
        case .rampRight: return "Take the slip road on the right"
        case .forkLeft, .keepLeft: return "Keep left"
        case .forkRight, .keepRight: return "Keep right"
        case .roundabout: return "At the roundabout, continue"
        default: return "Continue"
        }
    }

    static func parseStep(_ s: String) -> Maneuver {
        func attr(_ pattern: String) -> String? {
            guard let r = s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
            let m = String(s[r])
            guard let q1 = m.firstIndex(of: "'") else { return nil }
            return String(m[m.index(after: q1)...].dropLast())
        }
        let token = attr(#"maneuver='[^']+'"#)
        let side = attr(#"side='[^']+'"#)
        let severity = attr(#"\btype='[^']+'"#)
        let meters = Double(attr(#"meters='[0-9]+'"#) ?? "") ?? 0
        let road = s.range(of: #"<road>[^<]+</road>"#, options: .regularExpression).map {
            String(s[$0]).replacingOccurrences(of: "<road>", with: "").replacingOccurrences(of: "</road>", with: "")
        }
        var text = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespaces)
        var lane: String?
        if let r = text.range(of: #"^(Use (the .+? lanes?|any lane)) to "#, options: [.regularExpression, .caseInsensitive]) {
            lane = String(text[r]).replacingOccurrences(of: " to ", with: "").trimmingCharacters(in: .whitespaces)
            text.removeSubrange(r)
        }
        text = text.capitalizedFirst
        var m = Maneuver(type: mapType(token, side: side, severity: severity),
                         instruction: text.isEmpty ? "Continue" : text,
                         location: LatLng(0, 0), alongMeters: 0, distanceMeters: meters, road: road, laneHint: lane)
        // A slip road with no side ("Take the M3 slip road" is ON_RAMP alone): not a merge, whatever
        // the side turns out to be. Until the line says which, the left (where most leave in Britain).
        if ["ON_RAMP", "OFF_RAMP", "RAMP"].contains(token?.uppercased() ?? ""), side == nil {
            m.type = .rampLeft
            m.sideUnknown = true
        }
        // Google says the exit only in words: keep the number too, for the roundabout picture.
        if m.type == .roundabout { m.exit = exitNumber(in: m.instruction) }
        return m
    }

    /** "take the 3rd exit" is 3. */
    public static func exitNumber(in text: String) -> Int? {
        let words = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8]
        let lower = text.lowercased()
        if let r = lower.range(of: #"(\d+)(st|nd|rd|th) exit"#, options: .regularExpression) {
            return Int(lower[r].prefix { $0.isNumber })
        }
        for (w, n) in words where lower.contains("\(w) exit") { return n }
        return nil
    }

    static func mapType(_ token: String?, side: String?, severity: String?) -> ManeuverType {
        let left = side?.uppercased() == "LEFT", right = side?.uppercased() == "RIGHT"
        let slight = severity?.uppercased() == "SLIGHT", sharp = severity?.uppercased() == "SHARP"
        func lr(_ l: ManeuverType, _ r: ManeuverType, _ f: ManeuverType) -> ManeuverType { left ? l : (right ? r : f) }
        switch token?.uppercased() ?? "" {
        case "DEPART": return .depart
        case "DESTINATION", "ARRIVE": return .arrive
        case "TURN_LEFT": return .turnLeft
        case "TURN_RIGHT": return .turnRight
        case "TURN_SLIGHT_LEFT": return .slightLeft
        case "TURN_SLIGHT_RIGHT": return .slightRight
        case "TURN_SHARP_LEFT": return .sharpLeft
        case "TURN_SHARP_RIGHT": return .sharpRight
        case "TURN":
            if slight { return lr(.slightLeft, .slightRight, .straight) }
            if sharp { return lr(.sharpLeft, .sharpRight, .straight) }
            return lr(.turnLeft, .turnRight, .straight)
        case "UTURN", "UTURN_LEFT", "UTURN_RIGHT": return .uturn
        case "STRAIGHT", "CONTINUE", "NAME_CHANGE": return .straight
        case "MERGE", "MERGE_LEFT", "MERGE_RIGHT": return .merge
        case "FORK", "FORK_LEFT", "FORK_RIGHT": return lr(.forkLeft, .forkRight, .straight)
        case "ON_RAMP", "OFF_RAMP", "RAMP", "RAMP_LEFT", "ON_RAMP_LEFT", "OFF_RAMP_LEFT",
             "RAMP_RIGHT", "ON_RAMP_RIGHT", "OFF_RAMP_RIGHT": return lr(.rampLeft, .rampRight, .rampLeft)
        case "KEEP", "KEEP_LEFT", "KEEP_RIGHT": return lr(.keepLeft, .keepRight, .straight)
        case let t where t.contains("ROUNDABOUT"): return .roundabout
        default: return (left || right) ? lr(.turnLeft, .turnRight, .unknown) : .unknown
        }
    }

    /**
     * Put the steps on the line from the end backwards: each one starts its step's length before the
     * next one. Google sometimes leaves out the first "Head north" step, so counting back from the end
     * keeps the turns where they really are; a missing start gets a "Head ..." step of its own.
     */
    static func place(_ steps: [Maneuver], on line: [LatLng]) -> [Maneuver] {
        guard !steps.isEmpty, line.count >= 2 else { return steps }
        let cum = Geo.cumulative(line)
        let total = cum.last ?? 0
        var body = steps
        if body.last?.type == .arrive { body.removeLast() }
        let stepTotal = body.reduce(0) { $0 + $1.distanceMeters }
        let scale = stepTotal > total && stepTotal > 0 ? total / stepTotal : 1
        var end = total
        var out: [Maneuver] = []
        for var m in body.reversed() {
            let start = max(0, end - m.distanceMeters * scale)
            m.alongMeters = start
            m.location = Geo.point(along: line, meters: start, cumulative: cum)
            if m.sideUnknown { m.type = rampSide(line, cumulative: cum, at: start); m.sideUnknown = false }
            out.insert(m, at: 0)
            end = start
        }
        if let first = out.first, first.alongMeters > 15 {
            let ahead = Geo.point(along: line, meters: min(30, first.alongMeters), cumulative: cum)
            out.insert(Maneuver(type: .depart, instruction: "Head " + compass(Geo.bearing(line[0], ahead)),
                                location: line[0], alongMeters: 0, distanceMeters: first.alongMeters,
                                road: nil, laneHint: nil), at: 0)
        }
        out.append(Maneuver(type: .arrive, instruction: steps.last?.type == .arrive ? steps.last!.instruction : "You have arrived",
                            location: line[line.count - 1], alongMeters: total, distanceMeters: 0, road: nil, laneHint: nil))
        return out
    }

    /**
     * Which side a slip road leaves on, from the route line: the way the line bends from the road
     * before to the slip road after, and where it hardly bends, the side traffic keeps to (a slip
     * road off a British road is on the left).
     */
    static func rampSide(_ line: [LatLng], cumulative cum: [Double], at along: Double) -> ManeuverType {
        let total = cum.last ?? 0
        func heading(_ a: Double, _ b: Double) -> Double? {
            let p = Geo.point(along: line, meters: max(0, a), cumulative: cum), q = Geo.point(along: line, meters: min(total, b), cumulative: cum)
            return p.distance(to: q) > 3 ? Geo.bearing(p, q) : nil
        }
        let left = Geo.drivesOnLeft(Geo.point(along: line, meters: along, cumulative: cum))
        guard let a = heading(along - 60, along), let b = heading(along + 30, along + 150) else { return left ? .rampLeft : .rampRight }
        let turn = (b - a + 540).truncatingRemainder(dividingBy: 360) - 180
        if turn <= -15 { return .rampLeft }
        if turn >= 15 { return .rampRight }
        return left ? .rampLeft : .rampRight
    }

    static func compass(_ bearing: Double) -> String {
        let names = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        return names[Int(((bearing + 22.5) / 45).rounded(.down)) % 8]
    }
}
