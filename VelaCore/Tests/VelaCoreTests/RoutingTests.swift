import XCTest
@testable import VelaCore

final class RoutingTests: XCTestCase {
    func testDecodePolyline5() {
        // Google's documented example.
        let pts = Geo.decodePolyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@", precision: 1e5)
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts[0].lat, 38.5, accuracy: 1e-6)
        XCTAssertEqual(pts[0].lng, -120.2, accuracy: 1e-6)
        XCTAssertEqual(pts[2].lat, 43.252, accuracy: 1e-6)
        XCTAssertEqual(pts[2].lng, -126.453, accuracy: 1e-6)
    }

    func testGoogleStep() {
        let m = DirectionsParser.parseStep("<step maneuver='TURN' meters='120'>Turn <turn side='LEFT'>left</turn> onto <roadlist><road>Elm St</road></roadlist></step>")
        XCTAssertEqual(m.type, .turnLeft)
        XCTAssertEqual(m.distanceMeters, 120)
        XCTAssertEqual(m.road, "Elm St")
        XCTAssertEqual(m.instruction, "Turn left onto Elm St")
    }

    func testFoldedMotorwayStep() {
        // Google's long motorway stretch inside a folded group has no <step> text (Park Gate to Southampton, M27).
        let json = #"[[0,"",[12553,"7.8 mi",1],[486,"8 min"],null,null,null,[[[2612.7,-1.2584,50.8754],[0,0,0],[1024,768],13.1]],null,null,null,null,null,null,[[2,["Merge onto "]],[2,["M27",1]]]],null,["//maps.gstatic.com/tactile/directions/text_mode/maneuvers-2x.png","dir-tt dir-tt-merge"],null,null,"x",0]"#
        let entry = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [Any]
        let m = DirectionsParser.foldedStep(entry[0] as! [Any], icon: "dir-tt dir-tt-merge")
        XCTAssertEqual(m?.type, .merge)
        XCTAssertEqual(m?.distanceMeters, 12553)
        XCTAssertEqual(m?.road, "M27")
        XCTAssertEqual(m?.instruction, "Merge onto M27")
        let keep = #"[0,"",[900,"0.6 mi",1],[30,"30 sec"],null,null,null,null,null,null,null,null,null,null,[[2,["Keep "]],[2,["right",1]],[2,[" to stay on "]],[2,["M3",1]]]]"#
        let k = DirectionsParser.foldedStep(try! JSONSerialization.jsonObject(with: Data(keep.utf8)) as! [Any], icon: "dir-tt dir-tt-keep-right")
        XCTAssertEqual(k?.type, .keepRight)
        XCTAssertEqual(k?.road, "M3")
        // Found when reading a whole route's steps too.
        var steps: [Maneuver] = []
        DirectionsParser.collectSteps([[entry]], into: &steps)
        XCTAssertEqual(steps.map(\.distanceMeters), [12553])
        // A group header (no step text slot) and a normal step are left to the usual path.
        let header = try! JSONSerialization.jsonObject(with: Data(#"[0,null,[12967,"8.1 mi",1],[511,"9 min"]]"#.utf8)) as! [Any]
        XCTAssertNil(DirectionsParser.foldedStep(header, icon: nil))
        XCTAssertEqual(DirectionsParser.parseStep("<step maneuver='ON_RAMP' meters='209'>Slight left onto the ramp to So&#39;ton</step>").instruction,
                       "Slight left onto the ramp to So'ton")
    }

    /**
     * Google's "Take the M3 slip road" (Leigh Road, Eastleigh, 2026-10-29) is ON_RAMP with no side,
     * and showed a merge arrow. It's a slip road: the side comes from Google's icon, else the line.
     */
    func testSlipRoadWithNoSideIsNotAMerge() {
        let s = DirectionsParser.parseStep("<step maneuver='ON_RAMP' meters='300'>Use the left lane to take the <signlist><sign>M3</sign></signlist> slip road</step>")
        XCTAssertNotEqual(s.type, .merge)
        // North up Leigh Road, then the slip road bends away: left, right or straight on.
        let o = LatLng(50.97, -1.356)
        func line(_ bend: Double) -> [LatLng] {
            let k = cos(o.lat * .pi / 180) * 111_320
            let a = LatLng(o.lat + 500 / 110_540, o.lng)
            return [o, a, LatLng(a.lat + 300 * cos(bend * .pi / 180) / 110_540, a.lng + 300 * sin(bend * .pi / 180) / k)]
        }
        XCTAssertEqual(DirectionsParser.place([s], on: line(-35))[1].type, .rampLeft)
        XCTAssertEqual(DirectionsParser.place([s], on: line(35))[1].type, .rampRight)
        // Hardly bending: the side British traffic keeps to.
        XCTAssertEqual(DirectionsParser.place([s], on: line(4))[1].type, .rampLeft)
        // Google's icon beside the step says the side ("Exit at junction 10" with dir-tt-ramp-left).
        func entry(_ icon: String) -> [Any] {
            [[0, "<step maneuver='OFF_RAMP' meters='300'>Exit at junction 10</step>", [300, "0.2 mi", 1]] as [Any], NSNull(),
             ["//maps.gstatic.com/tactile/directions/text_mode/maneuvers-2x.png", icon]]
        }
        var steps: [Maneuver] = []
        DirectionsParser.collectSteps([entry("dir-tt dir-tt-ramp-right")], into: &steps)
        XCTAssertEqual(steps.map(\.type), [.rampRight])
        XCTAssertEqual(DirectionsParser.place(steps, on: line(-35))[1].type, .rampRight)
        // The open router's slip road straight on is on the traffic's side too, not always the right.
        XCTAssertEqual(OSRM.maneuverType("off ramp", "straight", leftTraffic: true), .rampLeft)
        XCTAssertEqual(OSRM.maneuverType("on ramp", nil, leftTraffic: false), .rampRight)
        XCTAssertEqual(OSRM.maneuverType("on ramp", "slight right", leftTraffic: true), .rampRight)
    }

    func testGeometryDeltas() {
        let g = DirectionsParser.decodeGeometry([[385_000_000, 10_000], [-1_217_000_000, -20_000]])
        XCTAssertEqual(g?.count, 2)
        XCTAssertEqual(g?[1].lat ?? 0, 38.501, accuracy: 1e-9)
        XCTAssertEqual(g?[1].lng ?? 0, -121.702, accuracy: 1e-9)
    }

    func testPbHasNoPlaceholdersLeft() {
        let pb = DirectionsPb.build(origin: LatLng(38.5, -121.7), destination: LatLng(38.7, -121.6), mode: .walk, avoidTolls: true)
        XCTAssertFalse(pb.contains("{"))
        XCTAssertFalse(pb.contains(" "))
        XCTAssertTrue(pb.contains("!1e2!2e3"))
        XCTAssertTrue(pb.hasPrefix("!1m4!3m2!3d38.5!4d-121.7!6e2!1m4!3m2!3d38.7!4d-121.6!6e2!3m12!1m3!1d"))
        XCTAssertTrue(pb.hasSuffix("!47m2!8b1!10e2"))
        let drive = DirectionsPb.build(origin: LatLng(1, 2), destination: LatLng(3, 4), mode: .drive, avoidTolls: true)
        XCTAssertTrue(drive.contains("!6m57!1m5!18b1!30b1!31m1!1b1!34e1!2m5!2b1!5m1"))
    }

    func testTracker() {
        // A straight 1.1 km line north with a turn in the middle and the arrival at the end.
        let line = [LatLng(0, 0), LatLng(0.005, 0), LatLng(0.01, 0)]
        let total = Geo.length(line)
        let route = Route(mode: .drive, polyline: line, distanceMeters: total, typicalSeconds: 100, trafficSeconds: nil,
                          summary: nil, maneuvers: [
                            Maneuver(type: .depart, instruction: "Go", location: line[0], alongMeters: 0, distanceMeters: total / 2),
                            Maneuver(type: .turnLeft, instruction: "Turn", location: line[1], alongMeters: total / 2, distanceMeters: total / 2),
                            Maneuver(type: .arrive, instruction: "Arrive", location: line[2], alongMeters: total, distanceMeters: 0),
                          ], source: "osm")
        let t = RouteTracker(route: route)
        let p = t.update(LatLng(0.0025, 0.0001))
        XCTAssertEqual(p.nextIndex, 1)
        XCTAssertEqual(p.distanceToNext, total / 4, accuracy: 5)
        XCTAssertEqual(p.remainingSeconds, 75, accuracy: 1)
        XCTAssertFalse(p.offRoute)
        // Three fixes far away: off route.
        _ = t.update(LatLng(0.006, 0.01))
        _ = t.update(LatLng(0.006, 0.01))
        XCTAssertTrue(t.update(LatLng(0.006, 0.01)).offRoute)
        XCTAssertTrue(t.update(LatLng(0.00999, 0)).arrived)
    }

    func testWrongWayIsOffRoute() {
        // Matteo's wrong turn: back on the route's road but driving south down a route going north.
        // It used to snap him onto the route the wrong way and never reroute.
        let line = [LatLng(0, 0), LatLng(0.005, 0), LatLng(0.01, 0)]
        let total = Geo.length(line)
        let route = Route(mode: .drive, polyline: line, distanceMeters: total, typicalSeconds: 100, trafficSeconds: nil,
                          summary: nil, maneuvers: [
                            Maneuver(type: .depart, instruction: "Go", location: line[0], alongMeters: 0, distanceMeters: total),
                            Maneuver(type: .arrive, instruction: "Arrive", location: line[2], alongMeters: total, distanceMeters: 0),
                          ], source: "osm")
        let t = RouteTracker(route: route)
        XCTAssertFalse(t.update(LatLng(0.004, 0), heading: 2).offRoute, "going the right way")
        var lat = 0.004
        var off = false
        for _ in 0..<4 { lat -= 0.0001; off = t.update(LatLng(lat, 0), heading: 180).offRoute }
        XCTAssertTrue(off, "four fixes driving the wrong way down the route")
        // Without a heading (standing still, or no compass course) nothing changes.
        let t2 = RouteTracker(route: route)
        for _ in 0..<6 { XCTAssertFalse(t2.update(LatLng(0.004, 0)).offRoute) }
    }

    func testNoMergeWhenTheLaneRunsToTheExit() {
        // Matteo near Redbridge: the slip road joins Redbridge Road from the left, then leaves at
        // the next exit on the left. No "Merge onto", and "left lane" for the exit instead.
        let p = LatLng(50.92, -1.47)
        let steps = [
            Maneuver(type: .depart, instruction: "Head out", location: p, alongMeters: 0, distanceMeters: 300),
            Maneuver(type: .merge, instruction: "Merge onto Redbridge Road", location: p, alongMeters: 300, distanceMeters: 400),
            Maneuver(type: .rampLeft, instruction: "Take the exit onto A33", location: p, alongMeters: 700, distanceMeters: 500),
            Maneuver(type: .arrive, instruction: "Arrive", location: p, alongMeters: 1200, distanceMeters: 0),
        ]
        let out = OSRM.keepLaneThroughMerges(steps, mergeSides: [1: "slight right"])
        XCTAssertEqual(out.map(\.type), [.depart, .rampLeft, .arrive])
        XCTAssertEqual(out[0].distanceMeters, 700)
        XCTAssertEqual(out[1].lanes.map(\.valid), [true, false], "left lane lit")
        // Exiting on the far side: the merge is real and stays.
        var far = steps
        far[2].type = .rampRight
        XCTAssertEqual(OSRM.keepLaneThroughMerges(far, mergeSides: [1: "slight right"]).count, 4)
    }

    func testStepsOnlyFromARouteOnTheSameRoads() {
        // About 2.2 km north; the other route leaves the line halfway for a parallel road 100 m east.
        let line = [LatLng(0, 0), LatLng(0.02, 0)]
        let cum = Geo.cumulative(line)
        XCTAssertTrue(StepMerge.follows([LatLng(0, 0.0001), LatLng(0.02, 0.0001)], line, cumulative: cum))
        XCTAssertFalse(StepMerge.follows([LatLng(0, 0), LatLng(0.01, 0), LatLng(0.01, 0.001), LatLng(0.02, 0.001)], line, cumulative: cum))
        // Checked both ways: the line goes up to a roundabout and back, the other route turns round early.
        let loop = [LatLng(0, 0), LatLng(0.01, 0), LatLng(0.01, 0.004), LatLng(0.01, 0), LatLng(0.02, 0)]
        XCTAssertTrue(StepMerge.follows(line, loop, cumulative: Geo.cumulative(loop)))
        XCTAssertFalse(StepMerge.follows(loop, line, cumulative: cum))
        // Matching asks for a point about every 150 m, never more than 100.
        let url = OSRM.matchURL(line, mode: .drive)!.absoluteString
        XCTAssertTrue(url.contains("/match/v1/driving/"))
        XCTAssertEqual(url.components(separatedBy: "radiuses=")[1].components(separatedBy: "&")[0].split(separator: ";").count, 15)
        let long = OSRM.matchURL([LatLng(0, 0), LatLng(1, 0)], mode: .drive)!.absoluteString
        XCTAssertTrue(long.hasSuffix("&waypoints=0;99"), long)
    }

    func testGoogleLaneHintOnTheSameStep() {
        let p = LatLng(0, 0)
        var steps = [Maneuver(type: .merge, instruction: "Merge onto Redbridge Road", location: p, alongMeters: 1000, distanceMeters: 300)]
        let google = [Maneuver(type: .merge, instruction: "Merge onto Redbridge Rd", location: p, alongMeters: 1060, distanceMeters: 300, laneHint: "Use the right lane")]
        StepMerge.addGoogleLaneHints(&steps, from: google)
        XCTAssertEqual(steps[0].laneHint, "Use the right lane")
    }

    func testRerouteKeepsHeading() {
        let url = OSRM.routeURL(from: LatLng(50.9, -1.4), to: LatLng(50.8, -1.3), mode: .drive, heading: 271.6).absoluteString
        XCTAssertTrue(url.hasSuffix("&bearings=272,60;"), url)
        XCTAssertFalse(OSRM.routeURL(from: LatLng(50.9, -1.4), to: LatLng(50.8, -1.3), mode: .drive).absoluteString.contains("bearings"))
        // A route that sets off south while the car heads north starts behind it.
        let south = [LatLng(0.01, 0), LatLng(0.009, 0), LatLng(0, 0)]
        XCTAssertTrue(Directions.startsBehind(south, heading: 0))
        XCTAssertFalse(Directions.startsBehind(south, heading: 175))
    }

    func testStepsPlacedFromTheEnd() {
        // About 1,113 m due north; Google gave only the last turn (300 m), not the "Head north" step.
        let line = [LatLng(0, 0), LatLng(0.01, 0)]
        let turn = DirectionsParser.parseStep("<step maneuver='TURN' meters='300'>Turn <turn side='LEFT'>left</turn></step>")
        let out = DirectionsParser.place([turn], on: line)
        XCTAssertEqual(out.map(\.type), [.depart, .turnLeft, .arrive])
        XCTAssertEqual(out[0].instruction, "Head north")
        XCTAssertEqual(out[1].alongMeters, Geo.length(line) - 300, accuracy: 0.5)
        XCTAssertEqual(out[2].alongMeters, Geo.length(line), accuracy: 0.5)
    }

    func testStepMergeOntoGoogleLine() {
        let google = [LatLng(0, 0), LatLng(0.01, 0)]
        func m(_ t: ManeuverType, _ lat: Double, _ text: String) -> Maneuver {
            Maneuver(type: t, instruction: text, location: LatLng(lat, 0.00004), alongMeters: 0, distanceMeters: 0, road: nil, laneHint: nil)
        }
        let osrm = Route(mode: .drive, polyline: google, distanceMeters: 1113, typicalSeconds: 100, trafficSeconds: nil, summary: nil,
                         maneuvers: [m(.depart, 0, "Drive north on A St"), m(.turnRight, 0.0045, "Turn right onto B St"), m(.arrive, 0.01, "You have arrived")],
                         source: "osm")
        let steps = StepMerge.adopt([osrm], onto: google)
        XCTAssertEqual(steps?.map(\.type), [.depart, .turnRight, .arrive])
        XCTAssertEqual(steps?[1].alongMeters ?? 0, Geo.length(google) * 0.45, accuracy: 2)
        XCTAssertEqual(steps?[0].distanceMeters ?? 0, Geo.length(google) * 0.45, accuracy: 2)
        // A route on other roads doesn't fit.
        let far = [LatLng(0, 0.01), LatLng(0.01, 0.01)]
        XCTAssertNil(StepMerge.adopt([osrm], onto: far))
    }

    func testSpeedLimits() {
        let line = [LatLng(0, 0), LatLng(0.001, 0), LatLng(0.002, 0), LatLng(0.003, 0)]
        let cum = Geo.cumulative(line)
        let legs: [[String: Any]] = [["annotation": ["maxspeed": [
            ["speed": 50.0, "unit": "km/h"], ["speed": 50.0, "unit": "km/h"], ["unknown": true],
        ]]]]
        let limits = OSRM.speedLimits(legs, line: line, cumulative: cum)
        XCTAssertEqual(limits.count, 2)
        XCTAssertEqual(limits[0].kmh, 50)
        XCTAssertNil(limits[1].kmh)
        XCTAssertEqual(limits[1].startMeters, cum[2], accuracy: 0.1)
        var r = Route(mode: .drive, polyline: line, distanceMeters: cum[3], typicalSeconds: 10, trafficSeconds: nil,
                      summary: nil, maneuvers: [], source: "osm")
        r.speedLimits = limits
        XCTAssertEqual(r.speedLimit(at: 10), 50)
        XCTAssertNil(r.speedLimit(at: cum[2] + 1))
    }

    func testLanes() {
        let step: [String: Any] = ["intersections": [["lanes": [
            ["indications": ["left"], "valid": true],
            ["indications": ["straight"], "valid": false],
            ["indications": ["straight", "right"], "valid": false],
        ]]]]
        let lanes = OSRM.lanes(step)
        XCTAssertEqual(lanes.count, 3)
        XCTAssertTrue(lanes[0].valid)
        XCTAssertEqual(lanes[2].indications, ["straight", "right"])
        let allValid: [String: Any] = ["intersections": [["lanes": [["indications": ["straight"], "valid": true], ["indications": ["straight"], "valid": true]]]]]
        XCTAssertTrue(OSRM.lanes(allValid).isEmpty, "every lane fine says nothing")
    }

    func testRoundaboutApproachLanes() {
        // M271 southbound, 70 m before Redbridge roundabout: a slip road leaves on the left there,
        // so those lanes aren't the roundabout's (the app once said "Middle lanes" for the 1st exit).
        let redbridge = LatLng(50.922617, -1.469691)
        let lanes: [[String: Any]] = [["indications": ["left"], "valid": false],
                                      ["indications": ["straight"], "valid": true],
                                      ["indications": ["straight"], "valid": true]]
        let slip: [String: Any] = ["location": [-1.4697, 50.9232], "in": 0, "out": 2,
                                   "entry": [false, true, true], "bearings": [0, 150, 180], "lanes": lanes]
        XCTAssertTrue(OSRM.approachLanes(slip, roundabout: redbridge, modifier: "slight left", leftTraffic: true).isEmpty)
        // The same lanes where nothing else leaves are the roundabout's, marked for its 1st exit.
        let plain: [String: Any] = ["location": [-1.4697, 50.9232], "in": 0, "out": 1,
                                    "entry": [false, true], "bearings": [0, 180], "lanes": lanes]
        let first = OSRM.approachLanes(plain, roundabout: redbridge, modifier: "slight left", leftTraffic: true)
        XCTAssertEqual(first.map(\.valid), [true, false, false])
        // Too far back to say anything about the roundabout.
        var far = plain
        far["location"] = [-1.4697, 50.9300]
        XCTAssertTrue(OSRM.approachLanes(far, roundabout: redbridge, modifier: "slight left", leftTraffic: true).isEmpty)
    }

    func testSlipRoadWording() {
        let off = OSRM.instruction(type: "off ramp", modifier: "slight left", road: "M27", exit: nil, mode: .drive,
                                   signs: .init(destinations: "A335: Eastleigh, Southampton", exits: "5", from: "M27"))
        XCTAssertEqual(off, "Take exit 5 toward Eastleigh and Southampton")
        let bracket = OSRM.instruction(type: "off ramp", modifier: "slight left", road: "M27", exit: nil, mode: .drive,
                                       signs: .init(destinations: "A32: (A32) Alton, Fareham", exits: "10", from: "M27"))
        XCTAssertEqual(bracket, "Take exit 10 toward Alton and Fareham")
        let bare = OSRM.instruction(type: "off ramp", modifier: "slight left", road: "M27", exit: nil, mode: .drive,
                                    signs: .init(destinations: nil, exits: nil, from: "M27"))
        XCTAssertEqual(bare, "Take the exit", "no 'toward M27' while leaving the M27")
        let on = OSRM.instruction(type: "on ramp", modifier: "slight left", road: "M27", exit: nil, mode: .drive,
                                  signs: .init(destinations: nil, exits: nil, from: "A27"))
        XCTAssertEqual(on, "Take the slip road onto M27")
        XCTAssertEqual(OSRM.instruction(type: "continue", modifier: "right", road: "A3222", exit: nil, mode: .drive),
                       "Turn right to stay on A3222")
        XCTAssertEqual(OSRM.instruction(type: "continue", modifier: "uturn", road: "Bridge Road", exit: nil, mode: .drive),
                       "Make a U-turn on Bridge Road")
    }

    func testNamedRoundaboutWording() {
        XCTAssertEqual(OSRM.instruction(type: "roundabout", modifier: nil, road: "Millbrook Roundabout", exit: nil, mode: .drive),
                       "Go straight through Millbrook Roundabout")
        XCTAssertEqual(OSRM.instruction(type: "roundabout", modifier: nil, road: "Redbridge Roundabout", exit: 2, mode: .drive),
                       "At Redbridge Roundabout, take the 2nd exit")
        XCTAssertEqual(OSRM.instruction(type: "roundabout", modifier: nil, road: "A33", exit: 3, mode: .drive),
                       "At the roundabout, take the 3rd exit onto A33")
    }
}

final class SpokenTextTests: XCTestCase {
    func testRoadNamesSaidInFull() {
        XCTAssertEqual(SpokenText.forVoice("Take the exit toward Stoneham Wy."), "Take the exit toward Stoneham Way.")
        XCTAssertEqual(SpokenText.forVoice("Slight left onto the ramp to So'ton"), "Slight left onto the ramp to Southampton")
        XCTAssertEqual(SpokenText.forVoice("Turn right onto Burgess Rd"), "Turn right onto Burgess Road")
        XCTAssertEqual(SpokenText.forVoice("Turn left onto Princes St."), "Turn left onto Princes Street.")
        XCTAssertEqual(SpokenText.forVoice("Turn left onto St Mary's Rd"), "Turn left onto Saint Mary's Road")
        XCTAssertEqual(SpokenText.forVoice("At St Mary's Roundabout, take the 2nd exit"), "At Saint Mary's Roundabout, take the 2nd exit")
        XCTAssertEqual(SpokenText.forVoice("Merge onto A33 N"), "Merge onto A33 north")
        XCTAssertEqual(SpokenText.forVoice("Merge onto A57(M)"), "Merge onto A57 M")
        XCTAssertEqual(SpokenText.forVoice("Turn left onto Princes St. Then turn right"), "Turn left onto Princes Street. Then turn right")
        XCTAssertEqual(SpokenText.forVoice("Starting route. Head toward Highfield Rd."), "Starting route. Head toward Highfield Road.")
        // Words that only start like a short form stay as they are.
        XCTAssertEqual(SpokenText.forVoice("Continue onto Drove Road toward Romsey"), "Continue onto Drove Road toward Romsey")
        XCTAssertEqual(SpokenText.forVoice("Turn left onto Avenue Road"), "Turn left onto Avenue Road")
    }
}

final class ExitNumberTests: XCTestCase {
    func testExitFromWords() {
        XCTAssertEqual(DirectionsParser.exitNumber(in: "At the roundabout, take the 3rd exit onto Hill Ln"), 3)
        XCTAssertEqual(DirectionsParser.exitNumber(in: "At the roundabout, take the 12th exit"), 12)
        XCTAssertEqual(DirectionsParser.exitNumber(in: "At the roundabout, take the second exit"), 2)
        XCTAssertNil(DirectionsParser.exitNumber(in: "At the roundabout, continue straight"))
    }
}

final class BritishWordsTests: XCTestCase {
    func testRampIsSlipRoad() {
        XCTAssertEqual(British.words("Take the ramp to Southampton"), "Take the slip road to Southampton")
        XCTAssertEqual(British.words("Slight left onto the ramp to So'ton"), "Slight left onto the slip road to So'ton")
        XCTAssertEqual(British.words("Turn left onto Rampart Road"), "Turn left onto Rampart Road")
        XCTAssertEqual(British.words("Exit the parking lot toward Park Walk"), "Exit the car park toward Park Walk")
    }
}


final class GoogleExitTests: XCTestCase {
    func testGoogleExitCountWins() {
        var a = Maneuver(type: .roundabout, instruction: "Go straight through Millbrook Roundabout", location: LatLng(0, 0),
                         alongMeters: 2662, distanceMeters: 60, road: "Millbrook Roundabout", laneHint: nil)
        var off = Maneuver(type: .roundabout, instruction: "Exit the roundabout onto Tebourba Way", location: LatLng(0, 0),
                           alongMeters: 2726, distanceMeters: 0, road: "Tebourba Way", laneHint: nil)
        off.leavesRoundabout = true
        off.exit = 1
        a.exit = nil
        var steps = [a, off]
        var g = Maneuver(type: .roundabout, instruction: "At the roundabout, take the 2nd exit", location: LatLng(0, 0),
                         alongMeters: 2660, distanceMeters: 0, road: nil, laneHint: nil)
        g.exit = 2
        StepMerge.addGoogleExits(&steps, from: [g])
        XCTAssertEqual(steps[0].exit, 2)
        XCTAssertEqual(steps[0].instruction, "At Millbrook Roundabout, take the 2nd exit")
        XCTAssertEqual(steps[1].exit, 2)
    }
}

final class DestinationSideTests: XCTestCase {
    func testSide() {
        // Driving north up a road; a place 30 m east of the end is on the right.
        let line = [LatLng(50.900, -1.400), LatLng(50.901, -1.400)]
        XCTAssertEqual(Geo.sideAtEnd(LatLng(50.901, -1.3996), of: line), "right")
        XCTAssertEqual(Geo.sideAtEnd(LatLng(50.901, -1.4004), of: line), "left")
        XCTAssertNil(Geo.sideAtEnd(LatLng(50.901, -1.400), of: line), "on the road itself")
        XCTAssertNil(Geo.sideAtEnd(LatLng(50.910, -1.3996), of: line), "a kilometre past the end")
    }
}
