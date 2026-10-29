import Foundation
import VelaCore

/**
 * `swift run vela-probe ramps [n]`: every slip road, merge, fork and keep step on drives across
 * the M3, M27, M25, M1, A34 and town dual carriageways, with Google's own step markup (its
 * maneuver and side), the step Kite ends up with, its arrow, and which way the route line really
 * goes there. Flags an arrow that disagrees with the line (a merge arrow where the route turns off).
 */
func rampAudit() async {
    let drives: [(String, LatLng, LatLng)] = [
        ("Leigh Road onto the M3 at J13 (Eastleigh)", LatLng(50.9700, -1.3560), LatLng(51.0630, -1.3080)),
        ("Chandler's Ford onto the M3 north", LatLng(50.9840, -1.3830), LatLng(51.0700, -1.2850)),
        ("Eastleigh to Southampton via M3 south", LatLng(50.9677, -1.3500), LatLng(50.9100, -1.4000)),
        ("Winchester to Southampton (M3 J9 to J14)", LatLng(51.0630, -1.3080), LatLng(50.9346, -1.3966)),
        ("Southampton to Portsmouth (M27)", LatLng(50.9150, -1.3800), LatLng(50.8050, -1.0870)),
        ("Portsmouth to Southampton (M27)", LatLng(50.8050, -1.0870), LatLng(50.9150, -1.3800)),
        ("Totton to Fareham (M27 J2 to J11)", LatLng(50.9190, -1.4900), LatLng(50.8520, -1.1790)),
        ("Marchwood onto the M271 and M27", LatLng(50.8880, -1.4420), LatLng(50.9620, -1.3640)),
        ("Hedge End onto the M27 west", LatLng(50.9120, -1.3000), LatLng(50.9420, -1.4380)),
        ("Winchester to Newbury (A34)", LatLng(51.0630, -1.3080), LatLng(51.4010, -1.3230)),
        ("Basingstoke onto the M3 to Fleet", LatLng(51.2660, -1.0870), LatLng(51.2840, -0.8400)),
        ("Heathrow to the M25 and M4", LatLng(51.4700, -0.4540), LatLng(51.5100, -0.6000)),
        ("M1 Luton to Milton Keynes", LatLng(51.8800, -0.4200), LatLng(52.0400, -0.7590)),
        ("Cardiff onto the M4 (Wales)", LatLng(51.4810, -3.1790), LatLng(51.5880, -2.9970)),
        ("Birmingham onto the M6 and M42", LatLng(52.4800, -1.9000), LatLng(52.4500, -1.7300)),
        ("Manchester onto the M60", LatLng(53.4800, -2.2400), LatLng(53.4300, -2.3500)),
        ("Leeds onto the M62", LatLng(53.8000, -1.5500), LatLng(53.7300, -1.6500)),
        ("Bristol onto the M32 and M4", LatLng(51.4550, -2.5900), LatLng(51.5300, -2.5100)),
        ("Glasgow onto the M8 (Scotland)", LatLng(55.8600, -4.2500), LatLng(55.8600, -4.4200)),
        ("Edinburgh bypass (Scotland)", LatLng(55.9300, -3.2900), LatLng(55.9000, -3.1000)),
        ("Newcastle onto the A1(M)", LatLng(54.9700, -1.6100), LatLng(54.9000, -1.5800)),
        ("London North Circular to the M1", LatLng(51.5900, -0.2200), LatLng(51.6400, -0.2700)),
        ("Reading onto the M4", LatLng(51.4500, -0.9700), LatLng(51.4300, -1.1200)),
        ("Swindon Magic Roundabout onto the M4", LatLng(51.5600, -1.7800), LatLng(51.5200, -1.7200)),
    ]
    let only = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) : nil
    var flags = 0, checked = 0
    for (n, d) in drives.enumerated() where only == nil || only == n {
        print("##### \(n): \(d.0)")
        // Google's own markup, for its maneuver names and sides.
        if let raw = try? await GoogleClient.shared.directionsBody(from: d.1, to: d.2, mode: .drive) {
            let body = raw.replacingOccurrences(of: "\\u003c", with: "<").replacingOccurrences(of: "\\u003e", with: ">")
                .replacingOccurrences(of: "\\u0027", with: "'").replacingOccurrences(of: "\\u0026", with: "&").replacingOccurrences(of: "\\\"", with: "\"")
            var seen = Set<String>()
            let steps = matches(#"<step [^>]*>.*?</step>"#, in: body)
            for s in steps where seen.insert(s).inserted {
                let lower = s.lowercased()
                guard ["ramp", "merge", "fork", "keep", "slip", "exit", "lane"].contains(where: lower.contains) else { continue }
                let attrs = matches(#"(maneuver|side|type)='[^']+'"#, in: s).joined(separator: " ")
                let words = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                print("  G  \(attrs.isEmpty ? "(no maneuver)" : attrs)  \"\(words)\"")
            }
            // Every icon with the words Google put just before it (folded steps, and steps whose markup has no maneuver).
            for f in matches(#"[^<>]{0,300}dir-tt-[a-z-]+"#, in: body) where !f.contains("roundabout") && !f.contains("dir-tt-straight") {
                let words = matches(#"\"[A-Za-z][^"]{0,80}\""#, in: f).suffix(6).joined(separator: " ")
                print("  G icon \(matches(#"dir-tt-[a-z-]+"#, in: f).last ?? "?")  \(words)")
            }
        } else { print("  G  no answer") }
        let r = await Directions.routes(from: d.1, to: d.2, mode: .drive)
        guard var x = r.routes.first else { print("FLAG no route: \(r.error ?? "")"); continue }
        if let a = await Roundabouts.apply(to: x) { x = a }
        for m in x.maneuvers where m.type == .roundabout && !m.leavesRoundabout {
            let rule = m.roundabout.map { s in "in=\(s.entryLanes.map(String.init) ?? "?")\(s.entryArrows.map { " arrows=" + $0.joined(separator: "|") } ?? "") rule=" + (s.ruleLanes(leftTraffic: true, hint: m.laneHint)?.map { $0.valid ? "*" : "." }.joined() ?? "none") } ?? "no picture"
            let mapped = m.lanes.isEmpty ? "" : " mapped=" + m.lanes.map { ($0.valid ? "*" : "") + $0.indications.joined(separator: "/") }.joined(separator: "|")
            print(String(format: "  RB %6.0f m  \"%@\"  hint=%@  %@%@  %.5f,%.5f", m.alongMeters, m.instruction, m.laneHint ?? "-", rule, mapped, m.location.lat, m.location.lng))
        }
        let line = x.polyline, cum = Geo.cumulative(line), total = cum.last ?? 0
        func heading(_ a: Double, _ b: Double) -> Double? {
            let p = Geo.point(along: line, meters: max(0, a), cumulative: cum), q = Geo.point(along: line, meters: min(total, b), cumulative: cum)
            return p.distance(to: q) > 3 ? Geo.bearing(p, q) : nil
        }
        print(String(format: "  %.1f km, source %@, %d steps", x.distanceMeters / 1000, x.source, x.maneuvers.count))
        for m in x.maneuvers where !m.silent {
            let kinds: [ManeuverType] = [.merge, .rampLeft, .rampRight, .forkLeft, .forkRight, .keepLeft, .keepRight]
            let words = m.instruction.lowercased()
            guard kinds.contains(m.type) || words.contains("slip road") || words.contains("exit") && !words.contains("roundabout") else { continue }
            checked += 1
            // Which way the line goes: the 60 m before against 30 to 150 m after.
            var turn: Double?
            if let a = heading(m.alongMeters - 60, m.alongMeters), let b = heading(m.alongMeters + 30, m.alongMeters + 150) {
                turn = (b - a + 540).truncatingRemainder(dividingBy: 360) - 180
            }
            var note = ""
            if m.type == .merge && !words.hasPrefix("merge") { note = "merge arrow for a step that isn't a merge" }
            if let t = turn, (m.type == .rampLeft || m.type == .forkLeft || m.type == .keepLeft) && t > 20 { note = "left arrow but the route goes right" }
            if let t = turn, (m.type == .rampRight || m.type == .forkRight || m.type == .keepRight) && t < -20 { note = "right arrow but the route goes left" }
            if !note.isEmpty { flags += 1 }
            print(String(format: "%@ %6.0f m  %-10@ turn=%@  \"%@\"  %.5f,%.5f%@", note.isEmpty ? "  ok  " : "FLAG", m.alongMeters, "\(m.type)",
                         turn.map { String(format: "%+.0f", $0) } ?? "?", m.instruction, m.location.lat, m.location.lng, note.isEmpty ? "" : "  <- " + note))
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }
    print("SUMMARY \(checked) slip road, merge and fork steps, \(flags) flagged")
}

private func matches(_ pattern: String, in s: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
    return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
}
