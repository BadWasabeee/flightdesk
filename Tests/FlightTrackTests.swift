import XCTest

final class FlightTrackTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func waypoints(endingAgo seconds: Double) -> [[Any]] {
        let end = now.timeIntervalSince1970 - seconds
        return [[end - 600, 36.12, -86.68, 0, 0, false],
                [end - 300, 38.0, -87.0, 9000.0, 350, false],
                [end, 42.69, -87.83, 1524.0, 269, false]]
    }

    func testParsesRecentTrackEndingNearAircraft() throws {
        let t = try XCTUnwrap(FlightTrack(waypoints: waypoints(endingAgo: 60), current: GeoPoint(lat: 42.7, lon: -87.9), now: now))
        XCTAssertEqual(t.points.count, 3)
        XCTAssertEqual(t.points.first?.point, GeoPoint(lat: 36.12, lon: -86.68))
        XCTAssertEqual(t.startAltitudeFt ?? -1, 0, accuracy: 0.1)
        XCTAssertLessThan(t.points[0].time, t.points[2].time)
    }

    func testRejectsStaleTrack() {
        XCTAssertNil(FlightTrack(waypoints: waypoints(endingAgo: 3600), current: nil, now: now))
    }

    func testRejectsTrackFromAnotherLeg() {
        // Track ends near Milwaukee, aircraft is over Denver.
        XCTAssertNil(FlightTrack(waypoints: waypoints(endingAgo: 60), current: GeoPoint(lat: 39.8, lon: -104.7), now: now))
    }

    func testAircraftClassFromTypeCode() {
        XCTAssertEqual(AircraftClass(typeCode: "B77W"), .wideBody)
        XCTAssertEqual(AircraftClass(typeCode: "A359"), .wideBody)
        XCTAssertEqual(AircraftClass(typeCode: "A20N"), .narrowBody)
        XCTAssertEqual(AircraftClass(typeCode: "B38M"), .narrowBody)
        XCTAssertEqual(AircraftClass(typeCode: "CRJ9"), .regional)
        XCTAssertEqual(AircraftClass(typeCode: "E75L"), .regional)
        XCTAssertEqual(AircraftClass(typeCode: "C172"), .light)
        XCTAssertEqual(AircraftClass(typeCode: "R44"), .rotorcraft)
        XCTAssertGreaterThan(AircraftClass.wideBody.iconScale, AircraftClass.regional.iconScale)
    }

    func testRemovingRepeatsDropsDuplicateVertices() {
        let a = GeoPoint(lat: 42, lon: -88), b = GeoPoint(lat: 42.5, lon: -88)
        XCTAssertEqual(FlightMath.removingRepeats([a, a, b, b, .init(lat: .nan, lon: 0), a]), [a, b, a])
    }

    func testDecodesBothFeedListNames() throws {
        let lol = try JSONDecoder().decode(ADSBResponse.self, from: Data(#"{"ac":[{"hex":"abc123"}]}"#.utf8))
        let fi = try JSONDecoder().decode(ADSBResponse.self, from: Data(#"{"aircraft":[{"hex":"abc123"}]}"#.utf8))
        XCTAssertEqual(lol.ac?.count, 1)
        XCTAssertEqual(fi.ac?.count, 1)
    }
}
