import XCTest

final class FlightDetailTests: XCTestCase {

    private let jfk = GeoPoint(lat: 40.64, lon: -73.78)
    private let lhr = GeoPoint(lat: 51.47, lon: -0.46)

    // MARK: Great circle

    func testGreatCircleEndpointsAndCount() throws {
        let path = FlightMath.greatCircle(from: jfk, to: lhr, count: 64)
        XCTAssertEqual(path.count, 64)
        let first = try XCTUnwrap(path.first), last = try XCTUnwrap(path.last)
        XCTAssertEqual(first.lat, jfk.lat, accuracy: 1e-6); XCTAssertEqual(first.lon, jfk.lon, accuracy: 1e-6)
        XCTAssertEqual(last.lat, lhr.lat, accuracy: 1e-6); XCTAssertEqual(last.lon, lhr.lon, accuracy: 1e-6)
    }

    func testGreatCircleBulgesPoleward() {
        // JFK→LHR's great circle passes well north of both airports (over Newfoundland/the North Atlantic).
        let maxLat = FlightMath.greatCircle(from: jfk, to: lhr).map(\.lat).max() ?? 0
        XCTAssertGreaterThan(maxLat, 51.5)
    }

    func testGreatCirclePointsAreEvenlySpaced() {
        let path = FlightMath.greatCircle(from: jfk, to: lhr, count: 11)
        let total = FlightService.gcDistance(jfk.lat, jfk.lon, lhr.lat, lhr.lon)
        for (a, b) in zip(path, path.dropFirst()) {
            XCTAssertEqual(FlightService.gcDistance(a.lat, a.lon, b.lat, b.lon), total / 10, accuracy: 0.5)
        }
    }

    func testGreatCircleSamePoint() {
        XCTAssertEqual(FlightMath.greatCircle(from: jfk, to: jfk), [jfk, jfk])
    }

    // MARK: Time to go

    func testTimeToGo() throws {
        XCTAssertEqual(try XCTUnwrap(FlightMath.timeToGo(remainingNM: 450, speedKT: 450)), 3600, accuracy: 0.001)
        XCTAssertNil(FlightMath.timeToGo(remainingNM: 100, speedKT: 40))
    }

    func testDurationText() {
        XCTAssertEqual(FlightMath.durationText(20), "< 1 m")
        XCTAssertEqual(FlightMath.durationText(12 * 60), "12 m")
        XCTAssertEqual(FlightMath.durationText(83 * 60), "1 h 23 m")
    }

    func testCompassPoint() {
        XCTAssertEqual(FlightMath.compassPoint(0), "N")
        XCTAssertEqual(FlightMath.compassPoint(359), "N")
        XCTAssertEqual(FlightMath.compassPoint(95), "E")
        XCTAssertEqual(FlightMath.compassPoint(202.5), "SSW")
        XCTAssertEqual(FlightMath.compassPoint(-90), "W")
    }

    // MARK: Per-aircraft record

    private func report(_ json: String) throws -> AircraftReport? {
        let record = try JSONDecoder().decode(DetailAircraftRecord.self, from: Data(json.utf8))
        return AircraftReport(record: record, observer: jfk, now: Date(timeIntervalSince1970: 1_000))
    }

    func testDecodesAirborneRecordWithSquawk() throws {
        let r = try XCTUnwrap(report("""
        {"hex":"a12758","flight":"UAL1551 ","r":"N17349","t":"B38M","alt_baro":8850,"gs":212.3,"track":183.2,
         "baro_rate":2432,"squawk":"1753","lat":40.70,"lon":-74.26,"seen_pos":4}
        """))
        XCTAssertEqual(r.flight.callsign, "UAL1551")
        XCTAssertEqual(r.flight.altitude, 8850)
        XCTAssertEqual(r.squawk, "1753")
        XCTAssertFalse(r.onGround)
        XCTAssertEqual(r.positionTime, Date(timeIntervalSince1970: 996))
        XCTAssertEqual(r.flight.distance, FlightService.gcDistance(jfk.lat, jfk.lon, 40.70, -74.26), accuracy: 1e-9)
    }

    func testKeepsGroundTrafficAndLastPosition() throws {
        let r = try XCTUnwrap(report("""
        {"hex":"abc123","alt_baro":"ground","gs":12,"lastPosition":{"lat":40.64,"lon":-73.78,"seen_pos":120}}
        """))
        XCTAssertTrue(r.onGround)
        XCTAssertEqual(r.flight.altitude, 0)
        XCTAssertEqual(r.flight.reg, "ABC123")
        XCTAssertNil(r.squawk)
        XCTAssertEqual(r.positionTime, Date(timeIntervalSince1970: 880))
    }

    func testRecordWithoutPositionIsDropped() throws {
        XCTAssertNil(try report(#"{"hex":"abc123","alt_baro":30000}"#))
    }
}
