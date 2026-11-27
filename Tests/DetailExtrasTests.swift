import XCTest

/// Sky position geometry, Planespotters response parsing and build-year decoding.
final class DetailExtrasTests: XCTestCase {

    private let observer = GeoPoint(lat: 51.47, lon: -0.46)
    /// One nautical mile in degrees of latitude.
    private let nmLat = 1.0 / 60

    // MARK: Sky position

    func testDirectlyOverheadIsStraightUp() {
        let sky = SkyPosition(observer: observer, aircraft: observer, altitudeFt: 35_000)
        XCTAssertEqual(sky.elevation, 90, accuracy: 1e-6)
        XCTAssertTrue(sky.isAboveHorizon)
        XCTAssertEqual(sky.slantRangeNM, 35_000 * 0.3048 / 1852, accuracy: 0.001)
    }

    func testNearlyOverheadIsSteep() {
        let sky = SkyPosition(observer: observer, aircraft: GeoPoint(lat: observer.lat + 0.5 * nmLat, lon: observer.lon),
                              altitudeFt: 10_000)
        XCTAssertGreaterThan(sky.elevation, 70)
    }

    func testElevationMatchesFlatGeometryNearby() {
        // 10 nm away at 6,076 ft (1 nm up): about atan(1/10) ≈ 5.7°, minus a little for curvature.
        let sky = SkyPosition(observer: observer, aircraft: GeoPoint(lat: observer.lat + 10 * nmLat, lon: observer.lon),
                              altitudeFt: 6_076.1)
        XCTAssertEqual(sky.elevation, 5.6, accuracy: 0.2)
        XCTAssertEqual(sky.slantRangeNM, 10.05, accuracy: 0.1)
    }

    func testFarAwayLowAircraftIsLowInTheSky() {
        let sky = SkyPosition(observer: observer, aircraft: GeoPoint(lat: observer.lat + 100 * nmLat, lon: observer.lon),
                              altitudeFt: 38_000)
        XCTAssertTrue(sky.isAboveHorizon)
        XCTAssertLessThan(sky.elevation, 3)
        XCTAssertGreaterThan(sky.elevation, 0)
    }

    func testVeryDistantLowAircraftIsBelowTheHorizon() {
        // Horizon distance for 2,000 ft is about 48 nm; at 150 nm it's hidden by the Earth.
        let sky = SkyPosition(observer: observer, aircraft: GeoPoint(lat: observer.lat + 150 * nmLat, lon: observer.lon),
                              altitudeFt: 2_000)
        XCTAssertLessThan(sky.elevation, 0)
        XCTAssertFalse(sky.isAboveHorizon)
    }

    func testCurvatureLowersElevation() {
        // Flat-earth elevation would be atan(35,000 ft / 250 nm) ≈ 1.3°; curvature drops it below 0.
        let sky = SkyPosition(observer: observer, aircraft: GeoPoint(lat: observer.lat + 250 * nmLat, lon: observer.lon),
                              altitudeFt: 35_000)
        XCTAssertLessThan(sky.elevation, 0)
    }

    func testAzimuthCardinalDirections() {
        let d = 0.2
        let cosLat = cos(observer.lat * .pi / 180)
        let cases: [(GeoPoint, Double, String)] = [
            (GeoPoint(lat: observer.lat + d, lon: observer.lon), 0, "N"),
            (GeoPoint(lat: observer.lat, lon: observer.lon + d / cosLat), 90, "E"),
            (GeoPoint(lat: observer.lat - d, lon: observer.lon), 180, "S"),
            (GeoPoint(lat: observer.lat, lon: observer.lon - d / cosLat), 270, "W"),
        ]
        for (target, expected, name) in cases {
            let sky = SkyPosition(observer: observer, aircraft: target, altitudeFt: 20_000)
            let diff = abs((sky.azimuth - expected + 540).truncatingRemainder(dividingBy: 360) - 180)
            XCTAssertLessThan(diff, 0.5, "\(name): \(sky.azimuth)")
            XCTAssertEqual(sky.compassPoint, name)
        }
    }

    func testAzimuthNorthEastAndAgreesWithBearing() {
        let target = GeoPoint(lat: observer.lat + 0.1, lon: observer.lon + 0.16)
        let sky = SkyPosition(observer: observer, aircraft: target, altitudeFt: 15_000)
        let bearing = FlightService.initialBearing(observer.lat, observer.lon, target.lat, target.lon)
        XCTAssertEqual(sky.azimuth, bearing, accuracy: 0.3)
        XCTAssertEqual(sky.compassPoint, "NE")
        XCTAssertTrue((0..<360).contains(sky.azimuth))
    }

    func testAzimuthAcrossTheAntimeridianAndSouthernHemisphere() {
        let fiji = GeoPoint(lat: -17.75, lon: 179.9)
        let sky = SkyPosition(observer: fiji, aircraft: GeoPoint(lat: -17.75, lon: -179.9), altitudeFt: 30_000)
        XCTAssertEqual(sky.azimuth, 90, accuracy: 0.5)
        XCTAssertGreaterThan(sky.elevation, 10)
    }

    // MARK: Planespotters parsing

    func testParsesPhotoResponse() throws {
        let json = """
        {"photos":[{"id":"1853108","thumbnail":{"src":"https://t.plnspttrs.net/11524/1853108_b1213d2ddb_t.jpg","size":{"width":200,"height":133}},
        "thumbnail_large":{"src":"https://t.plnspttrs.net/11524/1853108_b1213d2ddb_280.jpg","size":{"width":420,"height":280}},
        "link":"https://www.planespotters.net/photo/1853108/ei-ejg?utm_source=api","photographer":"GZ-T16"}]}
        """
        let photo = try XCTUnwrap(AircraftPhotos.parse(Data(json.utf8)))
        XCTAssertEqual(photo.imageURL.absoluteString, "https://t.plnspttrs.net/11524/1853108_b1213d2ddb_280.jpg")
        XCTAssertEqual(photo.pageURL.host, "www.planespotters.net")
        XCTAssertEqual(photo.aspectRatio, 1.5, accuracy: 1e-9)
        XCTAssertEqual(photo.credit, "© GZ-T16 / Planespotters.net")
    }

    func testEmptyPhotoListIsAValidMiss() throws {
        XCTAssertNil(try AircraftPhotos.parse(Data(#"{"photos":[]}"#.utf8)))
    }

    func testMalformedResponseIsAFailure() {
        XCTAssertThrowsError(try AircraftPhotos.parse(Data("<html>".utf8)))
    }

    func testPhotoWithoutLinkIsSkipped() throws {
        let json = #"{"photos":[{"thumbnail_large":{"src":"https://t.plnspttrs.net/a.jpg"},"photographer":"X"}]}"#
        XCTAssertNil(try AircraftPhotos.parse(Data(json.utf8)))
    }

    func testCacheFreshness() throws {
        let photo = try XCTUnwrap(URL(string: "https://example.org/a.jpg")).absoluteURL
        let hit = AircraftPhotos.Entry(photo: AircraftPhoto(imageURL: photo, width: nil, height: nil, pageURL: photo, photographer: ""),
                                       at: Date(timeIntervalSinceNow: -3 * 86_400))
        let miss = AircraftPhotos.Entry(photo: nil, at: Date(timeIntervalSinceNow: -3 * 86_400))
        XCTAssertTrue(AircraftPhotos.isFresh(hit))
        XCTAssertFalse(AircraftPhotos.isFresh(miss))
        XCTAssertFalse(AircraftPhotos.isFresh(AircraftPhotos.Entry(photo: hit.photo, at: Date(timeIntervalSinceNow: -8 * 86_400))))
    }

    // MARK: Build year

    private func report(_ extra: String) throws -> AircraftReport? {
        let json = #"{"hex":"a4c98f","lat":40.7,"lon":-73.9,"alt_baro":5000\#(extra)}"#
        let record = try JSONDecoder().decode(DetailAircraftRecord.self, from: Data(json.utf8))
        return AircraftReport(record: record, observer: nil)
    }

    func testBuildYearDecoding() throws {
        XCTAssertEqual(try report(#","year":"2023""#)?.year, 2023)
        XCTAssertEqual(try report(#","year":2009"#)?.year, 2009)
        XCTAssertNil(try report("")?.year)
        XCTAssertNil(try report(#","year":"unknown""#)?.year)
        XCTAssertNil(try report(#","year":null"#)?.year)
    }
}
