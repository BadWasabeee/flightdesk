import XCTest

final class RouteGeometryTests: XCTestCase {

    private let jfk = GeoPoint(lat: 40.64, lon: -73.78)
    private let lhr = GeoPoint(lat: 51.47, lon: -0.46)

    private func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double { FlightService.gcDistance(a.lat, a.lon, b.lat, b.lon) }

    // MARK: Nearest point on a segment

    func testNearestAlongSegment() {
        let n = RouteGeometry.nearest(on: GeoPoint(lat: 0, lon: 0), GeoPoint(lat: 0, lon: 10), to: GeoPoint(lat: 1, lon: 5))
        XCTAssertEqual(n.distance, 60, accuracy: 0.5)   // 1° of latitude ≈ 60 nm
        XCTAssertEqual(n.fraction, 0.5, accuracy: 0.01)
    }

    func testNearestClampsToEnds() {
        let a = GeoPoint(lat: 0, lon: 0), b = GeoPoint(lat: 0, lon: 10)
        let before = RouteGeometry.nearest(on: a, b, to: GeoPoint(lat: 0, lon: -2))
        XCTAssertEqual(before.fraction, 0)
        XCTAssertEqual(before.distance, 120, accuracy: 0.5)
        let after = RouteGeometry.nearest(on: a, b, to: GeoPoint(lat: 0, lon: 12))
        XCTAssertEqual(after.fraction, 1)
        XCTAssertEqual(after.distance, 120, accuracy: 0.5)
    }

    // MARK: Split at the aircraft

    func testSplitMidRoute() throws {
        let path = FlightMath.greatCircle(from: jfk, to: lhr)
        let aircraft = path[30]
        let (flown, remaining) = RouteGeometry.split(path, at: aircraft)
        let start = try XCTUnwrap(remaining.first), end = try XCTUnwrap(remaining.last)
        XCTAssertEqual(start, aircraft)
        XCTAssertEqual(distance(end, lhr), 0, accuracy: 0.01)
        XCTAssertEqual(distance(try XCTUnwrap(flown.first), jfk), 0, accuracy: 0.01)
        XCTAssertEqual(distance(try XCTUnwrap(flown.last), aircraft), 0, accuracy: 0.5)
        // Together they cover the whole route, with nothing behind the aircraft left in the dashed part.
        let total = distance(jfk, lhr)
        XCTAssertEqual(pathLength(flown) + pathLength(remaining), total, accuracy: 2)
        XCTAssertEqual(pathLength(remaining), distance(aircraft, lhr), accuracy: 2)
    }

    func testSplitOffRouteStartsAtAircraft() throws {
        let path = [GeoPoint(lat: 0, lon: 0), GeoPoint(lat: 0, lon: 5), GeoPoint(lat: 0, lon: 10)]
        let aircraft = GeoPoint(lat: 0.5, lon: 6)   // 30 nm north of the route, past the middle fix
        let (flown, remaining) = RouteGeometry.split(path, at: aircraft)
        XCTAssertEqual(remaining, [aircraft, GeoPoint(lat: 0, lon: 10)])
        XCTAssertEqual(flown.count, 3)
        XCTAssertEqual(try XCTUnwrap(flown.last).lon, 6, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(flown.last).lat, 0, accuracy: 0.01)
    }

    func testSplitBeforeDepartureKeepsWholeRoute() {
        let path = FlightMath.greatCircle(from: jfk, to: lhr)
        let (flown, remaining) = RouteGeometry.split(path, at: jfk)
        XCTAssertTrue(flown.isEmpty)
        XCTAssertEqual(pathLength(remaining), distance(jfk, lhr), accuracy: 1)
    }

    func testSplitAtDestinationLeavesNothingAhead() {
        let path = FlightMath.greatCircle(from: jfk, to: lhr)
        XCTAssertTrue(RouteGeometry.split(path, at: lhr).remaining.isEmpty)
    }

    func testSplitHasNoRepeatedVertices() {
        let path = FlightMath.greatCircle(from: jfk, to: lhr)
        // Exactly on a vertex: the projected point and the vertex must not both be kept.
        let (flown, remaining) = RouteGeometry.split(path, at: path[20])
        for line in [flown, remaining] {
            for (a, b) in zip(line, line.dropFirst()) { XCTAssertGreaterThanOrEqual(distance(a, b), 0.01) }
        }
    }

    func testSplitDegeneratePath() {
        XCTAssertTrue(RouteGeometry.split([], at: jfk).remaining.isEmpty)
        XCTAssertTrue(RouteGeometry.split([lhr], at: jfk).remaining.isEmpty)
    }

    // MARK: Antimeridian

    func testAntimeridianSplitEastbound() throws {
        let line = [GeoPoint(lat: 10, lon: 178), GeoPoint(lat: 12, lon: -178)]
        let parts = RouteGeometry.antimeridianSafe(line)
        XCTAssertEqual(parts.count, 2)
        let west = try XCTUnwrap(parts.first), east = try XCTUnwrap(parts.last)
        XCTAssertEqual(west.last?.lon, 180)
        XCTAssertEqual(east.first?.lon, -180)
        XCTAssertEqual(try XCTUnwrap(west.last?.lat), 11, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(east.first?.lat), 11, accuracy: 1e-9)
    }

    func testAntimeridianSplitWestbound() throws {
        let parts = RouteGeometry.antimeridianSafe([GeoPoint(lat: 0, lon: -179), GeoPoint(lat: 0, lon: 179)])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts.first?.last?.lon, -180)
        XCTAssertEqual(parts.last?.first?.lon, 180)
    }

    func testAntimeridianLeavesOrdinaryLinesWhole() {
        let path = FlightMath.greatCircle(from: jfk, to: lhr)
        XCTAssertEqual(RouteGeometry.antimeridianSafe(path), [path])
        XCTAssertEqual(RouteGeometry.antimeridianSafe([jfk]), [])
    }

    func testTranspacificRouteSplitsOnce() {
        // Tokyo Haneda → San Francisco crosses the antimeridian.
        let path = FlightMath.greatCircle(from: GeoPoint(lat: 35.55, lon: 139.78), to: GeoPoint(lat: 37.62, lon: -122.38))
        let parts = RouteGeometry.antimeridianSafe(path)
        XCTAssertEqual(parts.count, 2)
        for part in parts {
            for (a, b) in zip(part, part.dropFirst()) { XCTAssertLessThan(abs(a.lon - b.lon), 180) }
        }
    }

    // MARK: Heading vector

    func testHeadingVectorLength() throws {
        let p = GeoPoint(lat: 45, lon: 5)
        let line = RouteGeometry.headingVector(from: p, track: 90, speedKT: 480, minutes: 10)
        XCTAssertEqual(distance(p, try XCTUnwrap(line.first)), 0, accuracy: 1e-6)
        XCTAssertEqual(distance(p, try XCTUnwrap(line.last)), 80, accuracy: 0.1)
        XCTAssertGreaterThan(try XCTUnwrap(line.last).lon, p.lon)
    }

    func testHeadingVectorNeedsSpeed() {
        XCTAssertTrue(RouteGeometry.headingVector(from: jfk, track: 90, speedKT: 20).isEmpty)
    }

    func testHeadingVectorWrapsLongitude() throws {
        let line = RouteGeometry.headingVector(from: GeoPoint(lat: 0, lon: 179.9), track: 90, speedKT: 500)
        XCTAssertLessThan(try XCTUnwrap(line.last).lon, 0)
        XCTAssertEqual(RouteGeometry.antimeridianSafe(line).count, 2)
    }

    // MARK: Detail camera (opens locally, never fits the whole route)

    func testLocalSpanFollowsSearchRadius() {
        XCTAssertEqual(DetailCamera.localSpanNM(radiusNM: 50), 120, accuracy: 1e-9)
        XCTAssertEqual(DetailCamera.localSpanNM(radiusNM: 5), 60)      // close-up floor
        XCTAssertEqual(DetailCamera.localSpanNM(radiusNM: 250), 400)   // regional ceiling
    }

    func testLocalRegionIsCentredOnTheAircraftNotTheRoute() throws {
        // An ultra-long-haul aircraft mid-Pacific: the opening view stays local to it.
        let aircraft = GeoPoint(lat: 20, lon: -160)
        let fr = DetailCamera.localRegion(around: aircraft, radiusNM: 50)
        XCTAssertEqual(fr.center, aircraft)
        XCTAssertEqual(fr.latitudeDelta, 2, accuracy: 1e-9)   // 120 nm
        XCTAssertEqual(fr.longitudeDelta, 2 / cos(20 * Double.pi / 180), accuracy: 1e-9)
        let route = FlightMath.greatCircle(from: GeoPoint(lat: 1.36, lon: 103.99), to: GeoPoint(lat: 40.64, lon: -73.78))
        let whole = try XCTUnwrap(DetailFormat.framing(route + [aircraft]))
        XCTAssertGreaterThan(whole.latitudeDelta, fr.latitudeDelta * 10)
    }

    func testLocalRegionNearThePoleStaysBounded() {
        let fr = DetailCamera.localRegion(around: GeoPoint(lat: 89, lon: 0), radiusNM: 100)
        XCTAssertLessThanOrEqual(fr.longitudeDelta, 360)
        XCTAssertEqual(fr.longitudeDelta, fr.latitudeDelta / 0.2, accuracy: 1e-9)
    }

    private func pathLength(_ points: [GeoPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }
}
