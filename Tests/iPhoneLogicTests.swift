import XCTest

/// The iPhone app's pure logic: refresh cadence, deep links, map camera math and Lock Screen text.
final class IPhoneLogicTests: XCTestCase {
    private func flight(_ hex: String = "a1b2c3", callsign: String = "DAL1342", reg: String = "N123DL", type: String = "A321",
                        alt: Int = 12_450, dst: Double = 4.2, dir: Double = 45) -> Flight {
        let json = """
        {"hex":"\(hex)","flight":"\(callsign)","r":"\(reg)","t":"\(type)","alt_baro":\(alt),"gs":300,
         "track":90,"lat":43.1,"lon":-88.2,"dst":\(dst),"dir":\(dir)}
        """
        return Flight(adsb: try! JSONDecoder().decode(ADSBAircraft.self, from: Data(json.utf8)))!
    }

    private let mke = Airport(code: "MKE", city: "Milwaukee", lat: 42.95, lon: -87.9)
    private let ord = Airport(code: "ORD", city: "Chicago", lat: 41.98, lon: -87.9)

    // MARK: Refresh cadence

    func testLiveCadenceOnAdsbFiAndReceiver() {
        XCTAssertEqual(RefreshCadence.interval(source: nil, counts: [:], paused: []), RefreshCadence.live)
        XCTAssertEqual(RefreshCadence.interval(source: .feed(.adsbFi), counts: [.adsbLol: 400], paused: []), RefreshCadence.live)
        XCTAssertEqual(RefreshCadence.interval(source: .receiver, counts: [:], paused: [.adsbFi, .adsbLol]), RefreshCadence.live)
    }

    func testAdsbLolIsRationedThenRests() {
        XCTAssertEqual(RefreshCadence.interval(source: .feed(.adsbLol), counts: [.adsbLol: 10], paused: []), RefreshCadence.rationed)
        // 500 allowance − 60 reserve − 350 used = 90 left: under the low-water mark.
        XCTAssertEqual(RefreshCadence.interval(source: .feed(.adsbLol), counts: [.adsbLol: 350], paused: []), RefreshCadence.resting)
        XCTAssertEqual(RefreshCadence.remaining(.adsbLol, counts: [.adsbLol: 350]), 90)
        XCTAssertEqual(RefreshCadence.remaining(.adsbLol, counts: [.adsbLol: 9_999]), 0)
        XCTAssertEqual(RefreshCadence.remaining(.adsbFi, counts: [.adsbFi: 9_999]), .max)
    }

    func testEveryFeedPausedRestsAndLowPowerDoubles() {
        XCTAssertEqual(RefreshCadence.interval(source: .feed(.adsbFi), counts: [:], paused: [.adsbFi, .adsbLol]), RefreshCadence.resting)
        XCTAssertEqual(RefreshCadence.interval(source: .feed(.adsbFi), counts: [:], paused: [.adsbFi]), RefreshCadence.live)
        XCTAssertEqual(RefreshCadence.interval(source: .feed(.adsbFi), counts: [:], paused: [], lowPower: true), RefreshCadence.live * 2)
    }

    // MARK: Deep links

    func testAppLinks() {
        XCTAssertEqual(AppLink(url: URL(string: "flightdesk://flight/A1B2C3")!), .flight("a1b2c3"))
        XCTAssertEqual(AppLink(url: URL(string: "flightdesk://radar")!), .radar)
        XCTAssertEqual(AppLink(url: URL(string: "flightdesk://logbook")!), .logbook)
        let settings = URL(string: "flightdesk://settings/alerts")!
        XCTAssertEqual(AppLink(url: settings), .settings(settings))
    }

    func testAppLinksRejectOtherURLs() {
        XCTAssertNil(AppLink(url: URL(string: "flightdesk://flight/not-a-hex")!))
        XCTAssertNil(AppLink(url: URL(string: "flightdesk://flight/a1b2c3/extra")!))
        XCTAssertNil(AppLink(url: URL(string: "https://flight/a1b2c3")!))
        XCTAssertNil(AppLink(url: URL(string: "flightdesk://somewhere")!))
    }

    // MARK: Map camera

    private func viewport(obscured: Double) -> MapReveal.Viewport {
        MapReveal.Viewport(center: GeoPoint(lat: 43, lon: -88), latitudeDelta: 2, longitudeDelta: 2, obscuredBottom: obscured)
    }

    func testRevealLeavesVisibleAircraftAlone() {
        XCTAssertNil(MapReveal.center(revealing: GeoPoint(lat: 43.5, lon: -88), in: viewport(obscured: 0.5)))
        XCTAssertNil(MapReveal.center(revealing: GeoPoint(lat: 42.5, lon: -88.5), in: viewport(obscured: 0)))
    }

    func testRevealPansAircraftOutFromUnderTheSheetKeepingZoom() {
        // Half the map is under the sheet: the uncovered band is 43…44, so 42.5 is hidden.
        let v = viewport(obscured: 0.5)
        let c = try! XCTUnwrap(MapReveal.center(revealing: GeoPoint(lat: 42.5, lon: -88.2), in: v))
        // The aircraft lands in the middle of the uncovered band: half a band (0.5°) above the new centre.
        XCTAssertEqual(c.lat, 42.0, accuracy: 1e-9)
        XCTAssertEqual(c.lon, -88.2, accuracy: 1e-9)
        var moved = v
        moved.center = c
        XCTAssertNil(MapReveal.center(revealing: GeoPoint(lat: 42.5, lon: -88.2), in: moved))
    }

    func testRevealHandlesTheAntimeridian() {
        let v = MapReveal.Viewport(center: GeoPoint(lat: 0, lon: 179.5), latitudeDelta: 2, longitudeDelta: 2)
        XCTAssertNil(MapReveal.center(revealing: GeoPoint(lat: 0, lon: -179.8), in: v))
        let c = try! XCTUnwrap(MapReveal.center(revealing: GeoPoint(lat: 0, lon: -175), in: v))
        XCTAssertEqual(c.lon, -175, accuracy: 1e-9)
    }

    func testFramingFitsTheRadiusInTheUncoveredArea() {
        let observer = GeoPoint(lat: 43, lon: -88)
        let open = MapReveal.framing(around: observer, radiusNM: 25, obscuredBottom: 0)
        XCTAssertEqual(open.center.lat, 43, accuracy: 1e-9)
        XCTAssertEqual(open.latitudeDelta, 25.0 / 60 * 1.15 * 2, accuracy: 1e-9)
        let half = MapReveal.framing(around: observer, radiusNM: 25, obscuredBottom: 0.5)
        XCTAssertEqual(half.latitudeDelta, open.latitudeDelta * 2, accuracy: 1e-9)
        // The observer sits in the middle of the uncovered top half.
        let top = half.center.lat + half.latitudeDelta / 2
        XCTAssertEqual(top - half.latitudeDelta / 4, observer.lat, accuracy: 1e-9)
        XCTAssertEqual(half.longitudeDelta, open.longitudeDelta, accuracy: 1e-9)
    }

    // MARK: Lock Screen text

    func testNearestAndCompactNumbers() {
        let near = flight("aaaaaa", dst: 3.1), far = flight("bbbbbb", dst: 9.7)
        XCTAssertEqual(NearestFlightText.nearest([far, near])?.id, "aaaaaa")
        XCTAssertNil(NearestFlightText.nearest([]))
        XCTAssertEqual(NearestFlightText.distanceValue(4.24, units: .imperial), "4.2")
        XCTAssertEqual(NearestFlightText.distanceValue(12.6, units: .imperial), "13")
        XCTAssertEqual(NearestFlightText.distanceValue(4, units: .metric), "7.4")
        XCTAssertEqual(NearestFlightText.shortAltitude(12_450, units: .imperial), "12k ft")
        XCTAssertEqual(NearestFlightText.shortAltitude(8_500, units: .imperial), "8.5k ft")
        XCTAssertEqual(NearestFlightText.shortAltitude(850, units: .imperial), "850 ft")
        XCTAssertEqual(NearestFlightText.shortAltitude(12_000, units: .metric), "3.7k m")
        XCTAssertEqual(NearestFlightText.shortAltitude(0, units: .imperial), "GND")
    }

    func testRouteDetailAndInline() {
        var f = flight()
        XCTAssertNil(NearestFlightText.route(f))
        XCTAssertEqual(NearestFlightText.detail(f), "A321")
        XCTAssertEqual(NearestFlightText.inline(f, units: .imperial), "DAL1342 4.2 nm")
        f.route = RouteInfo(airline: "Delta Air Lines", flightNo: "DL1342", airlineCode: "DL", from: mke, to: ord)
        XCTAssertEqual(NearestFlightText.route(f), "MKE → ORD")
        XCTAssertEqual(NearestFlightText.detail(f), "MKE → ORD")
        XCTAssertEqual(NearestFlightText.inline(f, units: .imperial), "DL1342 MKE→ORD 4.2 nm")
        XCTAssertEqual(NearestFlightText.position(f, units: .imperial), "4.2 nm NE · 12k ft")
    }
}
