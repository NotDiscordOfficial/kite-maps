import XCTest
@testable import VelaCore

final class RoundaboutTests: XCTestCase {
    /** M27 junction 9 (Park Gate / Whiteley) from the north-west, as the open router answered on 2026-10-25: 5th exit. */
    let parkGate: [String: Any] = [
        "maneuver": ["type": "rotary", "exit": 5, "location": [-1.253292, 50.873558]],
        "intersections": [
            ["location": [-1.253292, 50.873558], "bearings": [120, 165, 330], "entry": [false, false, true], "in": 1, "out": 2],
            ["location": [-1.253542, 50.873819], "bearings": [0, 150, 315], "entry": [true, false, true], "in": 1, "out": 0],
            ["location": [-1.252877, 50.875028], "bearings": [75, 225, 255], "entry": [true, false, false], "in": 1, "out": 0],
            ["location": [-1.252625, 50.87509], "bearings": [75, 255, 345], "entry": [true, false, true], "in": 1, "out": 0],
            ["location": [-1.252442, 50.87513], "bearings": [60, 90, 255], "entry": [true, true, false], "in": 2, "out": 1],
            ["location": [-1.251731, 50.875004], "bearings": [135, 315, 345], "entry": [true, false, false], "in": 1, "out": 0],
            ["location": [-1.251667, 50.874959], "bearings": [75, 150, 315], "entry": [true, true, false], "in": 2, "out": 1],
        ] as [[String: Any]],
    ]
    let parkGateExit: [String: Any] = [
        "maneuver": ["type": "exit rotary", "location": [-1.251482, 50.874705]],
        "intersections": [
            ["location": [-1.251482, 50.874705], "bearings": [150, 165, 345], "entry": [true, true, false], "in": 2, "out": 0],
        ] as [[String: Any]],
    ]

    func testSketchCountsTheExitsPassed() throws {
        let s = try XCTUnwrap(OSRM.roundaboutSketch(parkGate, next: parkGateExit, clockwise: true))
        // Four exits passed on the way round, then yours: the 5th.
        XCTAssertEqual(s.exits.count, 5)
        XCTAssertEqual(s.taken, 4)
        XCTAssertFalse(s.complete)
        XCTAssertEqual(s.entriesOnly.count, 2)
        // Going round clockwise, each exit is further round than the one before.
        let turns = s.exits.indices.map(s.turn)
        XCTAssertEqual(turns, turns.sorted())
        XCTAssertTrue(turns.allSatisfy { $0 > 15 && $0 < 375 })
    }

    func testCircleFit() throws {
        let c = LatLng(51.0, -1.0)
        let pts = stride(from: 0.0, to: 300, by: 50).map { a -> LatLng in
            let r = 60.0
            return LatLng(c.lat + r * cos(a * .pi / 180) / 110_540, c.lng + r * sin(a * .pi / 180) / (111_320 * cos(51 * .pi / 180)))
        }
        let fit = try XCTUnwrap(OSRM.fitCircle(pts))
        XCTAssertLessThan(fit.distance(to: c), 2)
    }

    func testHighwayCodeLane() {
        // Keep left: first exit or straight on in the left lane, past 12 o'clock in the right.
        let left = RoundaboutShape(exits: [270, 0, 90], taken: 0, clockwise: true, complete: true)
        XCTAssertEqual(left.ruleLane, 0)
        var right = left
        right.taken = 2
        XCTAssertEqual(right.ruleLane, 1)
        var ahead = left
        ahead.taken = 1
        XCTAssertEqual(ahead.ruleLane, 0)
    }

    /** A plain four-way roundabout built by hand: ring, four two-way roads, the route going right (3rd exit in Britain). */
    func testShapeFromOpenStreetMap() throws {
        let c = LatLng(51.5, -0.1)
        let k = 111_320 * cos(51.5 * .pi / 180)
        func at(_ deg: Double, _ r: Double) -> LatLng {
            LatLng(c.lat + r * cos(deg * .pi / 180) / 110_540, c.lng + r * sin(deg * .pi / 180) / k)
        }
        // Ring nodes every 30 degrees, ids 1...12, closed.
        let ringIds: [Int64] = Array(1...12) + [1]
        let ringPts = (0..<12).map { at(Double($0) * 30, 30) } + [at(0, 30)]
        var ways = [Roundabouts.Way(id: 100, nodes: ringIds, points: ringPts, tags: ["junction": "roundabout", "highway": "primary"])]
        // Roads at north (node 1), east (4), south (7), west (10).
        for (i, deg) in [0.0, 90, 180, 270].enumerated() {
            let ring = Int64([1, 4, 7, 10][i])
            ways.append(Roundabouts.Way(id: Int64(200 + i), nodes: [ring, Int64(50 + i)], points: [at(deg, 30), at(deg, 120)],
                                        tags: ["highway": "primary"]))
        }
        // The route: up from the south, round clockwise (west, north) and out east.
        var line = [at(180, 200), at(180, 30)]
        for d in stride(from: 210.0, through: 450, by: 15) { line.append(at(d, 30)) }
        line.append(at(90, 200))
        let cum = Geo.cumulative(line)
        let along = Geo.project(at(180, 30), on: line, cumulative: cum).along
        let s = try XCTUnwrap(Roundabouts.shape(ways, entry: at(180, 30), line: line, cumulative: cum, along: along,
                                                clockwise: true, exitNumber: 3))
        // West, north, east, then back south: four exits, the third taken.
        XCTAssertEqual(s.exits.count, 4)
        XCTAssertEqual(s.taken, 2)
        XCTAssertTrue(s.complete)
        XCTAssertEqual(s.exits[0], 270, accuracy: 3)
        XCTAssertLessThan(Roundabouts.angleGap(s.exits[1], 0), 3)
        XCTAssertEqual(s.exits[2], 90, accuracy: 3)
        XCTAssertEqual(s.ruleLane, 1)
    }

    /** A dual carriageway meeting the circle with a way in and a way out is one road. */
    func testDualCarriagewayMerges() {
        let arms = [
            Roundabouts.Arm(angle: 80, canExit: true, canEnter: false, name: "A27"),
            Roundabouts.Arm(angle: 100, canExit: false, canEnter: true, name: "A27"),
            Roundabouts.Arm(angle: 200, canExit: true, canEnter: true, name: nil),
        ]
        let merged = Roundabouts.merge(arms)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].angle, 90, accuracy: 0.5)
        XCTAssertTrue(merged[0].canExit && merged[0].canEnter)
    }

    /**
     * Chestnut Avenue, Eastleigh (2026-10-27): "1st exit" straight on over a small roundabout. With
     * no exit passed the router has no sketch, and the picture used to put the 1st exit on the left.
     */
    func testFirstExitStraightOnPointsUp() throws {
        let c = LatLng(50.97, -1.37)
        let k = 111_320 * cos(50.97 * .pi / 180)
        func at(_ deg: Double, _ r: Double) -> LatLng {
            LatLng(c.lat + r * cos(deg * .pi / 180) / 110_540, c.lng + r * sin(deg * .pi / 180) / k)
        }
        // Up from the south, round the left side of a 12 m circle (clockwise), out to the north.
        var line = [at(180, 300), at(180, 12)]
        for d in stride(from: 200.0, through: 340, by: 20) { line.append(at(d, 12)) }
        line += [at(0, 12), at(0, 300)]
        let along = Geo.cumulative(line)[1]
        let m = Maneuver(type: .roundabout, instruction: "At the roundabout, take the 1st exit", location: at(180, 12),
                         alongMeters: along, distanceMeters: 300, exit: 1)
        let route = Route(mode: .drive, polyline: line, distanceMeters: 600, typicalSeconds: 60, trafficSeconds: nil,
                          summary: nil, maneuvers: [m], source: "osm")
        let s = try XCTUnwrap(Roundabouts.settle(route).maneuvers[0].roundabout)
        XCTAssertEqual(s.exits.count, 1)
        XCTAssertLessThan(Roundabouts.angleGap(s.exits[s.taken], 0), 15)
        XCTAssertEqual(s.ruleLane, 0)

        // Going left instead (out to the west): the picture says left.
        let west = [at(180, 300), at(180, 12), at(220, 12), at(250, 12), at(270, 12), at(270, 300)]
        let r2 = Route(mode: .drive, polyline: west, distanceMeters: 600, typicalSeconds: 60, trafficSeconds: nil,
                       summary: nil, maneuvers: [m], source: "osm")
        let s2 = try XCTUnwrap(Roundabouts.settle(r2).maneuvers[0].roundabout)
        XCTAssertLessThan(Roundabouts.angleGap(s2.exits[s2.taken], 270), 15)

        // A sketch that roughly agrees with the line keeps its exits, turned to match it.
        var sketched = route
        sketched.maneuvers[0].roundabout = RoundaboutShape(exits: [265, 5], taken: 1, clockwise: true, complete: false)
        let kept = try XCTUnwrap(Roundabouts.settle(sketched).maneuvers[0].roundabout)
        XCTAssertEqual(kept.exits.count, 2)
        XCTAssertLessThan(Roundabouts.angleGap(kept.exits[0], 265), 10)
        XCTAssertLessThan(Roundabouts.angleGap(kept.exits[1], 0), 15)
    }

    /**
     * Rownhams (M27 junction 3, 2026-10-28): a 120 m circle, in from the south and round the west
     * side to leave heading east. The ring is nearly straight for 40 m, and it was read as the way
     * out, so the M27 east exit was drawn as straight on.
     */
    func testBigRoundaboutExitIsReadOffTheRoadOut() throws {
        let c = LatLng(50.9455, -1.4763)
        let k = cos(c.lat * .pi / 180) * 111_320
        func at(_ deg: Double, _ r: Double) -> LatLng {
            LatLng(c.lat + r * cos(deg * .pi / 180) / 110_540, c.lng + r * sin(deg * .pi / 180) / k)
        }
        var line = [at(180, 500), at(180, 120)]
        for d in stride(from: 185.0, through: 420, by: 5) { line.append(at(d, 120)) }
        // Off the ring at 60 degrees (north-east), then east along the slip road.
        let off = at(60, 120)
        line.append(LatLng(off.lat, off.lng + 400 / k))
        let cum = Geo.cumulative(line)
        let entry = cum[1], leave = cum[line.count - 2]
        let withStep = try XCTUnwrap(Roundabouts.exitAngle(line, cumulative: cum, along: entry, leaving: leave))
        XCTAssertLessThan(Roundabouts.angleGap(withStep, 90), 10)
        let without = try XCTUnwrap(Roundabouts.exitAngle(line, cumulative: cum, along: entry))
        XCTAssertLessThan(Roundabouts.angleGap(without, 90), 10)
    }

    /** The Highway Code's lanes, as many as the road in has; none for a one-lane road in. */
    func testRuleLanesFollowTheRoadIn() throws {
        var s = RoundaboutShape(exits: [270, 0, 90], taken: 2, clockwise: true, complete: true)
        s.entryLanes = 3
        // Right on three lanes: the middle one too (Rownhams, M27 junction 3, from the M271).
        XCTAssertEqual(try XCTUnwrap(s.ruleLanes(leftTraffic: true)).map(\.valid), [false, true, true])
        s.taken = 1
        XCTAssertEqual(try XCTUnwrap(s.ruleLanes(leftTraffic: true)).map(\.valid), [true, true, false])
        s.taken = 0
        XCTAssertEqual(try XCTUnwrap(s.ruleLanes(leftTraffic: true)).map(\.valid), [true, false, false])
        s.entryLanes = nil
        XCTAssertEqual(try XCTUnwrap(s.ruleLanes(leftTraffic: true)).map(\.valid), [true, false])
        s.entryLanes = 1
        XCTAssertNil(s.ruleLanes(leftTraffic: true))
        // All the way round: the far lane only, however many there are.
        var lap = RoundaboutShape(exits: [270, 0, 90, 170], taken: 3, clockwise: true, complete: true)
        lap.entryLanes = 3
        XCTAssertEqual(try XCTUnwrap(lap.ruleLanes(leftTraffic: true)).map(\.valid), [false, false, true])
        // Painted arrows where the map has them (A339 into Basingstoke's M3 junction 6): those, not the rule.
        s.entryLanes = 4
        s.entryArrows = ["left", "left", "through", "through;right"]
        s.taken = 2
        XCTAssertEqual(try XCTUnwrap(s.ruleLanes(leftTraffic: true)).map(\.valid), [false, false, false, true])
        s.taken = 1
        XCTAssertEqual(try XCTUnwrap(s.ruleLanes(leftTraffic: true)).map(\.valid), [false, false, true, true])
        s.taken = 0
        XCTAssertEqual(try XCTUnwrap(s.ruleLanes(leftTraffic: true)).map(\.valid), [true, true, false, false])
        // Google's advice beats both (Basingstoke M3 junction 6: all four painted straight on, the M3 from the left three).
        s.entryArrows = ["left;through", "through", "through", "through"]
        s.taken = 2
        XCTAssertEqual(try XCTUnwrap(s.ruleLanes(leftTraffic: true, hint: "Use the left 3 lanes")).map(\.valid), [true, true, true, false])
        s.entryArrows = nil
        s.entryLanes = 2
        XCTAssertEqual(try XCTUnwrap(s.ruleLanes(leftTraffic: true, hint: "Use the right 2 lanes")).map(\.valid), [false, true, true])
        XCTAssertEqual(try XCTUnwrap(s.ruleLanes(leftTraffic: true, hint: "Use the lane 2nd from the left")).map(\.valid), [false, true, false])
        // Words that don't fit the road ("middle lane" of two) or "any lane": the rule as before.
        XCTAssertEqual(try XCTUnwrap(s.ruleLanes(leftTraffic: true, hint: "Use the middle lane")).map(\.valid), [false, true])
        XCTAssertEqual(try XCTUnwrap(s.ruleLanes(leftTraffic: true, hint: "Use any lane")).map(\.valid), [false, true])
        // A one-lane road in that Google says has a lane to pick: Google's word.
        s.entryLanes = 1
        XCTAssertEqual(try XCTUnwrap(s.ruleLanes(leftTraffic: true, hint: "Use the left lane")).map(\.valid), [true, false])
    }

    /**
     * The map's picture of a big roundabout (Holbrook Road, Portsmouth): the 1st exit touches the
     * ring just after you come on, so it was drawn pointing back down, but the road heads left.
     * Your exit is turned to where the road goes and the others keep their order round.
     */
    func testMapPictureAimsWhereTheRoadGoes() {
        let map = RoundaboutShape(exits: [195, 300, 12, 100], taken: 0, entriesOnly: [140], clockwise: true, complete: true)
        let s = Roundabouts.aim(map, at: 290)
        XCTAssertEqual(s.taken, 0)
        XCTAssertEqual(s.exits[0], 290, accuracy: 0.01)
        func round(_ a: Double) -> Double { (a - 180 + 360).truncatingRemainder(dividingBy: 360) }
        XCTAssertEqual(s.exits.map(round), s.exits.map(round).sorted())
        XCTAssertEqual(s.exits.count, 4)
        XCTAssertGreaterThan(round(s.entriesOnly[0]), round(s.exits[3]))

        // Already pointing the right way: hardly moves.
        let fine = Roundabouts.aim(RoundaboutShape(exits: [270, 0, 90], taken: 1, clockwise: true, complete: true), at: 5)
        XCTAssertEqual(fine.exits[0], 272.5, accuracy: 0.5)
        XCTAssertEqual(fine.exits[1], 5, accuracy: 0.01)
    }

    /**
     * Normandy Way, Marchwood (2026-10-27): straight over a mini-roundabout (one mapped point, a
     * side road off to the east) with no step from either router. It gets its own step.
     */
    func testMiniRoundaboutGetsAStep() throws {
        let c = LatLng(50.8957, -1.4469)
        let k = 111_320 * cos(50.8957 * .pi / 180)
        func at(_ deg: Double, _ r: Double) -> LatLng {
            LatLng(c.lat + r * cos(deg * .pi / 180) / 110_540, c.lng + r * sin(deg * .pi / 180) / k)
        }
        let ways = [
            Roundabouts.Way(id: 1, nodes: [10, 99, 11], points: [at(180, 200), c, at(0, 200)], tags: ["highway": "tertiary", "name": "Normandy Way"]),
            Roundabouts.Way(id: 2, nodes: [99, 12], points: [c, at(90, 150)], tags: ["highway": "service", "name": "Test Lane"]),
        ]
        let line = [at(180, 600), c, at(0, 600)]
        let steps = [
            Maneuver(type: .depart, instruction: "Drive along Normandy Way", location: line[0], alongMeters: 0, distanceMeters: 1000, road: "Normandy Way"),
            Maneuver(type: .turnLeft, instruction: "Turn left onto Cracknore Hard", location: line[2], alongMeters: 1000, distanceMeters: 200, road: "Cracknore Hard"),
            Maneuver(type: .arrive, instruction: "You have arrived", location: line[2], alongMeters: 1200, distanceMeters: 0),
        ]
        let route = Route(mode: .drive, polyline: line, distanceMeters: 1200, typicalSeconds: 120, trafficSeconds: nil,
                          summary: nil, maneuvers: steps, source: "google")
        let r = try XCTUnwrap(Roundabouts.withMinis(route, minis: [(99, c)], ways: ways))
        XCTAssertEqual(r.maneuvers.count, 4)
        let m = r.maneuvers[1]
        XCTAssertEqual(m.type, .roundabout)
        XCTAssertEqual(m.exit, 1)
        XCTAssertEqual(m.alongMeters, 600, accuracy: 6)
        XCTAssertEqual(m.instruction, "At the roundabout, take the 1st exit")
        XCTAssertEqual(r.maneuvers[0].distanceMeters, 600, accuracy: 6)
        XCTAssertEqual(m.distanceMeters, 400, accuracy: 6)
        let s = try XCTUnwrap(m.roundabout)
        XCTAssertTrue(s.mini)
        // Straight on is the 1st exit going round clockwise; the side road east is the 2nd.
        XCTAssertEqual(s.exits.count, 2)
        XCTAssertLessThan(Roundabouts.angleGap(s.exits[s.taken], 0), 5)
        XCTAssertEqual(s.exits[1], 90, accuracy: 5)
    }
}
