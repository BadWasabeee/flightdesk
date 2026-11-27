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

    // MARK: Detail formatting

    private let us = Locale(identifier: "en_US")

    func testDistanceUsesGroupingAndSensiblePrecision() {
        XCTAssertEqual(DetailFormat.distance(6424.4, units: .imperial, locale: us), "6,424 nm")
        XCTAssertEqual(DetailFormat.distance(3.74, units: .imperial, locale: us), "3.7 nm")
        XCTAssertEqual(DetailFormat.distance(9.96, units: .imperial, locale: us), "10 nm")
        XCTAssertEqual(DetailFormat.distance(1320.2, units: .imperial, locale: us), "1,320 nm")
        XCTAssertEqual(DetailFormat.distance(100, units: .metric, locale: us), "185 km")
        XCTAssertEqual(DetailFormat.distance(-1, units: .imperial, locale: us), "0.0 nm")
    }

    func testVerticalRate() {
        XCTAssertEqual(DetailFormat.verticalRate(64, units: .imperial, locale: us), "Level")
        XCTAssertEqual(DetailFormat.verticalRate(1_216, units: .imperial, locale: us), "+1,200 fpm")
        XCTAssertEqual(DetailFormat.verticalRate(-832, units: .imperial, locale: us), "-850 fpm")
        XCTAssertEqual(DetailFormat.verticalRate(1_000, units: .metric, locale: us), "+5.1 m/s")
    }

    func testHeadingIsThreeDigitsWithCompassPoint() {
        XCTAssertEqual(DetailFormat.heading(95.4), "095° E")
        XCTAssertEqual(DetailFormat.heading(359.7), "000° N")
        XCTAssertEqual(DetailFormat.heading(-90), "270° W")
    }

    func testBuiltAndAgo() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(DetailFormat.built(2009, now: now, calendar: cal), "2009 · 18 years old")
        XCTAssertEqual(DetailFormat.built(2026, now: now, calendar: cal), "2026 · 1 year old")
        XCTAssertEqual(DetailFormat.built(2027, now: now, calendar: cal), "2027")
        XCTAssertEqual(DetailFormat.ago(now.addingTimeInterval(-20), now: now), "just now")
        XCTAssertEqual(DetailFormat.ago(now.addingTimeInterval(-245), now: now), "4 min ago")
        XCTAssertEqual(DetailFormat.ago(now.addingTimeInterval(-7_500), now: now), "2 h 5 m ago")
    }

    func testSquawkAlerts() {
        XCTAssertEqual(DetailFormat.squawkAlert("7700"), "Emergency")
        XCTAssertEqual(DetailFormat.squawkAlert("7600"), "Radio Failure")
        XCTAssertEqual(DetailFormat.squawkAlert("7500"), "Hijack")
        XCTAssertNil(DetailFormat.squawkAlert("1200"))
        XCTAssertNil(DetailFormat.squawkAlert(nil))
    }

    func testArrivalStates() {
        XCTAssertEqual(DetailFormat.arrival(remainingNM: 2, speedKT: 0, altitudeFt: 0, verticalRate: 0, onGround: true), .landed)
        XCTAssertNil(DetailFormat.arrival(remainingNM: 900, speedKT: 10, altitudeFt: 0, verticalRate: 0, onGround: true))
        XCTAssertEqual(DetailFormat.arrival(remainingNM: 4, speedKT: 150, altitudeFt: 1_200, verticalRate: -700, onGround: false), .landing)
        XCTAssertEqual(DetailFormat.arrival(remainingNM: 450, speedKT: 450, altitudeFt: 36_000, verticalRate: 0, onGround: false),
                       .estimate(3_600))
        XCTAssertNil(DetailFormat.arrival(remainingNM: 450, speedKT: 20, altitudeFt: 36_000, verticalRate: 0, onGround: false))
    }

    func testMapDetailLevels() {
        XCTAssertEqual(DetailFormat.MapDetail(latitudeSpan: 1), .labelled)
        XCTAssertEqual(DetailFormat.MapDetail(latitudeSpan: 8), .icons)
        XCTAssertEqual(DetailFormat.MapDetail(latitudeSpan: 30), .hidden)
        XCTAssertLessThan(DetailFormat.MapDetail.hidden, .icons)
    }

    func testTitleAndSubtitle() throws {
        XCTAssertEqual(DetailFormat.title(for: nil, hex: "a1b2c3"), "A1B2C3")
        XCTAssertEqual(DetailFormat.subtitle(for: nil), "")
    }

    func testFramingSimpleRoute() throws {
        let fr = try XCTUnwrap(DetailFormat.framing([GeoPoint(lat: 36.08, lon: -115.15), GeoPoint(lat: 42.95, lon: -87.9)], margin: 0))
        XCTAssertEqual(fr.center.lon, -101.525, accuracy: 0.01)
        XCTAssertGreaterThan(fr.center.lat, 36.08)
        XCTAssertLessThan(fr.center.lat, 42.95)
        XCTAssertEqual(fr.longitudeDelta, 27.25, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(fr.latitudeDelta, 42.95 - 36.08)
    }

    func testFramingAcrossTheAntimeridian() throws {
        // Taipei to Chicago via Alaska: the frame must span the Pacific, not Europe.
        let pts = [GeoPoint(lat: 25.08, lon: 121.23), GeoPoint(lat: 60, lon: 180), GeoPoint(lat: 62, lon: -170), GeoPoint(lat: 41.98, lon: -87.9)]
        let fr = try XCTUnwrap(DetailFormat.framing(pts, margin: 0))
        XCTAssertEqual(fr.longitudeDelta, 150.87, accuracy: 0.01)
        XCTAssertEqual(fr.center.lon, -163.335, accuracy: 0.01)
    }

    func testFramingSinglePointHasMinimumSize() throws {
        let fr = try XCTUnwrap(DetailFormat.framing([GeoPoint(lat: 0, lon: 10)]))
        XCTAssertEqual(fr.latitudeDelta, 0.3, accuracy: 1e-9)
        XCTAssertEqual(fr.center.lon, 10, accuracy: 1e-9)
        XCTAssertNil(DetailFormat.framing([GeoPoint(lat: .nan, lon: 0)]))
    }

    func testLookUpCopy() {
        let overhead = SkyPosition(observer: observer, aircraft: GeoPoint(lat: observer.lat + 10 * nmLat, lon: observer.lon),
                                   altitudeFt: 30_000)
        let text = DetailFormat.lookUp(overhead)
        XCTAssertTrue(text.headline.hasPrefix("Look "))
        XCTAssertTrue(text.headline.hasSuffix("toward N"))
        XCTAssertEqual(text.detail, "Bearing 000°")
        let hidden = SkyPosition(observer: observer, aircraft: GeoPoint(lat: observer.lat + 150 * nmLat, lon: observer.lon), altitudeFt: 2_000)
        XCTAssertEqual(DetailFormat.lookUp(hidden).headline, "Below your horizon")
    }
}
