import XCTest
@testable import VelaCore

final class WazeTests: XCTestCase {
    func testVisibleReportsDoNotCountPrefetchMargin() {
        let a = WazeAlert(id: "inside", kind: .police, location: LatLng(-31.8, 116.0))
        let b = WazeAlert(id: "outside", kind: .hazard, location: LatLng(-31.7, 116.0))
        XCTAssertEqual(Waze.inViewport([a, b], south: -31.9, west: 115.9, north: -31.75, east: 116.1).map(\.id), ["inside"])
        let east = WazeAlert(id: "east", kind: .police, location: LatLng(0, 179.9))
        let west = WazeAlert(id: "west", kind: .police, location: LatLng(0, -179.9))
        XCTAssertEqual(Waze.inViewport([east, west], south: -1, west: 179, north: 1, east: -179).count, 2)
    }

    func testParse() {
        let json = #"{"alerts":[{"type":"POLICE","subtype":"POLICE_HIDING","uuid":"a1","location":{"x":-0.12,"y":51.5},"street":"A40","pubMillis":1700000000000,"nThumbsUp":3,"reliability":8,"magvar":90},{"type":"WEATHERHAZARD","subtype":"HAZARD_ON_ROAD_POT_HOLE","uuid":"a2","location":{"x":-0.1,"y":51.4}},{"type":"WEATHERHAZARD","subtype":"HAZARD_WEATHER_FOG","uuid":"a3","location":{"x":-0.1,"y":51.4}},{"type":"HAZARD","subtype":"HAZARD_ON_ROAD_CONSTRUCTION","uuid":"a4","location":{"x":-0.1,"y":51.4}},{"type":"CHIT_CHAT","uuid":"a5","location":{"x":0,"y":0}},{"type":"ROAD_CLOSED","uuid":"a6"}],"jams":[]}"#
        let list = Waze.parse(Data(json.utf8))!
        XCTAssertEqual(list.map(\.kind), [.police, .hazard, .weather, .roadworks])
        XCTAssertEqual(list[0].title, "Hidden police")
        XCTAssertEqual(list[0].thumbsUp, 3)
        XCTAssertEqual(list[0].heading, 90)
        XCTAssertEqual(list[0].location, LatLng(51.5, -0.12))
        XCTAssertEqual(list[0].reportedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(list[1].spoken, "Pothole reported ahead.")
        XCTAssertNil(Waze.parse(Data("nope".utf8)))
    }

    func testLiveAlertParse() {
        // A RealtimeAlert as Waze's app protocol sends it: police with a mobile camera west of Greenwich.
        var pos = ProtoWriter()
        pos.int32(101, -1_339_275)
        pos.int32(102, 50_905_133)
        var info = ProtoWriter()
        info.varint(1, 2)
        info.varint(2, 203)
        info.message(3, pos.data)
        info.varint(6, 270)
        var address = ProtoWriter()
        address.string(2, "A3024 Bursledon Rd")
        var report = ProtoWriter()
        report.varint(4, 1_793_107_490)
        report.message(8, address.data)
        report.varint(9, 12)
        var alert = ProtoWriter()
        alert.varint(1, 42)
        alert.message(2, info.data)
        alert.message(3, report.data)
        alert.string(6, "uuid-1")
        var action = ProtoWriter()
        action.message(1, alert.data)
        var element = ProtoWriter()
        element.message(2708, action.data)
        element.string(2001, "RmAlert,uuid-0")
        var batch = ProtoWriter()
        batch.message(1001, element.data)

        let parsed = try! WazeLive.parseBatch(batch.data)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].oldCommand, "RmAlert,uuid-0")
        let a = parsed[0].alert!
        XCTAssertEqual(a.id, "uuid-1")
        XCTAssertEqual(a.kind, .police)
        XCTAssertEqual(a.title, "Mobile speed camera")
        XCTAssertEqual(a.location.lat, 50.905133, accuracy: 1e-6)
        XCTAssertEqual(a.location.lng, -1.339275, accuracy: 1e-6)
        XCTAssertEqual(a.heading, 270)
        XCTAssertEqual(a.street, "A3024 Bursledon Rd")
        XCTAssertEqual(a.thumbsUp, 12)
        XCTAssertEqual(a.reportedAt, Date(timeIntervalSince1970: 1_793_107_490))
    }

    func testMapDisplayedLine() {
        let line = WazeLive.mapDisplayed((s: 50.0, w: -1.5, n: 51.0, e: -1.0))
        XCTAssertTrue(line.hasPrefix("MapDisplayed,-1.500000,51.000000,-1.000000,51.000000,-1.000000,50.000000,-1.500000,50.000000,-1.250000,50.500000,67186,-1.500000,51.000000"))
        XCTAssertEqual(WazeLive.region(LatLng(51.5, -0.12)), "row")
        XCTAssertEqual(WazeLive.region(LatLng(38.5, -121.7)), "na")
    }

    func testEnv() {
        XCTAssertEqual(Waze.env(for: LatLng(51.5, -0.12)), "row")
        XCTAssertEqual(Waze.env(for: LatLng(38.5, -121.7)), "na")
        XCTAssertEqual(Waze.env(for: LatLng(32.08, 34.78)), "il")
    }

    func testProjectKeepsOnlyOurDirection() {
        // A road heading due east.
        let line = [LatLng(0, 0), LatLng(0, 0.02)]
        let same = WazeAlert(id: "same", kind: .police, location: LatLng(0.0001, 0.01), heading: 85)
        let other = WazeAlert(id: "other", kind: .police, location: LatLng(-0.0001, 0.012), heading: 268)
        let unknown = WazeAlert(id: "unknown", kind: .accident, location: LatLng(0, 0.015))
        let far = WazeAlert(id: "far", kind: .police, location: LatLng(0.01, 0.01))
        let hits = Waze.project([same, other, unknown, far], on: line)
        XCTAssertEqual(hits.map(\.alert.id), ["same", "unknown"])
        XCTAssertEqual(hits[0].along, 1113, accuracy: 15)
    }

    func testHeadingWrapsAroundNorth() {
        // A road heading due north: a report heading 355° is the same way, 175° the other.
        let line = [LatLng(0, 0), LatLng(0.02, 0)]
        let same = WazeAlert(id: "same", kind: .police, location: LatLng(0.01, 0.0001), heading: 355)
        let other = WazeAlert(id: "other", kind: .police, location: LatLng(0.012, 0.0001), heading: 175)
        // A closure blocks both ways, whichever way its reporter drove.
        let closed = WazeAlert(id: "closed", kind: .closure, location: LatLng(0.015, 0), heading: 180)
        XCTAssertEqual(Waze.project([same, other, closed], on: line).map(\.alert.id), ["same", "closed"])
    }

    func testEdgeCases() {
        XCTAssertEqual(Waze.parse(Data(#"{"jams":[]}"#.utf8))?.count, 0)
        XCTAssertEqual(Waze.parse(Data(#"{"alerts":[]}"#.utf8))?.count, 0)
        XCTAssertNil(Waze.parse(Data("[1,2]".utf8)))
        XCTAssertTrue(Waze.project([WazeAlert(id: "a", kind: .police, location: LatLng(0, 0))], on: [LatLng(0, 0)]).isEmpty)
        XCTAssertEqual(Waze.kind(type: "JAM", subtype: "JAM_HEAVY_TRAFFIC"), .jam)
        XCTAssertEqual(Waze.kind(type: "WEATHERHAZARD", subtype: "HAZARD_ON_ROAD_ICE"), .weather)
        XCTAssertNil(Waze.kind(type: "CHIT_CHAT", subtype: ""))
        // A subtype Kite doesn't know still gets a sensible name from its kind.
        XCTAssertEqual(WazeAlert(id: "x", kind: .hazard, subtype: "HAZARD_SOMETHING_NEW", location: LatLng(0, 0)).title, "Hazard")
        XCTAssertEqual(WazeAlert(id: "x", kind: .closure, location: LatLng(0, 0)).spoken, "Road closed ahead.")
        XCTAssertTrue(Waze.url(south: 51, west: -1, north: 52, east: 0).absoluteString.contains("top=52.00000&bottom=51.00000&left=-1.00000&right=0.00000&env=row"))
    }

    func testEveryKindHasAName() {
        for k in WazeAlert.Kind.allCases {
            let a = WazeAlert(id: "x", kind: k, location: LatLng(0, 0))
            XCTAssertFalse(a.title.isEmpty)
            XCTAssertTrue(a.spoken.hasSuffix("ahead."))
        }
    }
}

final class PoliceRiskTests: XCTestCase {
    func testScore() {
        let road = [LatLng(51.5, -0.2), LatLng(51.5, -0.16)]
        let now = Date()
        XCTAssertEqual(PoliceRisk.score(ahead: road, past: [], live: 0, now: now), 0)
        XCTAssertEqual(PoliceRisk.level(PoliceRisk.score(ahead: road, past: [], live: 1, now: now)), .high)
        let near = (0..<2).map { _ in PoliceRisk.Report(LatLng(51.5002, -0.18), now.addingTimeInterval(-86_400 * 7)) }
        let far = (0..<20).map { _ in PoliceRisk.Report(LatLng(51.6, -0.18), now) }
        XCTAssertEqual(PoliceRisk.level(PoliceRisk.score(ahead: road, past: near, live: 0, now: now)), .medium)
        XCTAssertEqual(PoliceRisk.score(ahead: road, past: far, live: 0, now: now), 0)
        // Old reports count for less: the same two from a year ago are low.
        let old = near.map { PoliceRisk.Report($0.location, now.addingTimeInterval(-86_400 * 360)) }
        XCTAssertEqual(PoliceRisk.level(PoliceRisk.score(ahead: road, past: old, live: 0, now: now)), .low)
        // No road ahead (just arrived): only live reports matter.
        XCTAssertEqual(PoliceRisk.score(ahead: [], past: near, live: 0, now: now), 0)
        XCTAssertGreaterThan(PoliceRisk.score(ahead: [], past: [], live: 1, now: now), 60)
    }
}

final class AircraftTests: XCTestCase {
    func testParse() {
        let json = #"{"ac":[{"hex":"406f5c","flight":"NPAS15  ","r":"G-POLA","t":"EC35","lat":51.5,"lon":-0.1,"alt_baro":1500,"gs":90,"track":120},{"hex":"aaa","flight":"BAW123","ownOp":"British Airways","lat":51.4,"lon":-0.4,"alt_baro":9000},{"hex":"bbb","ownOp":"County of Los Angeles Sheriff","category":"A7","lat":34,"lon":-118,"alt_baro":800},{"hex":"ccc","flight":"UKP02","lat":51,"lon":0,"alt_baro":"ground"}]}"#
        let list = Aircraft.parse(Data(json.utf8))!
        XCTAssertEqual(list.map(\.id), ["406f5c", "bbb"])
        XCTAssertTrue(list[0].helicopter)
        XCTAssertEqual(list[0].callsign, "NPAS15")
        XCTAssertEqual(list[0].altitudeFeet, 1500)
        XCTAssertTrue(list[1].helicopter)
        XCTAssertEqual(list[1].title, "Police helicopter")
    }

    func testPoliceNames() {
        XCTAssertTrue(Aircraft.isPolice(callsign: "NPAS21", operatorName: nil))
        XCTAssertTrue(Aircraft.isPolice(callsign: nil, operatorName: "Bundespolizei"))
        XCTAssertTrue(Aircraft.isPolice(callsign: nil, operatorName: "California Highway Patrol"))
        XCTAssertFalse(Aircraft.isPolice(callsign: "EZY12AB", operatorName: "easyJet"))
        XCTAssertFalse(Aircraft.isPolice(callsign: nil, operatorName: nil))
        XCTAssertNil(Aircraft.parse(Data("oops".utf8)))
        XCTAssertEqual(Aircraft.parse(Data(#"{"ac":[]}"#.utf8))?.count, 0)
    }
}
