import XCTest

final class FlightCoreTests: XCTestCase {

    private func flight(callsign: String = "SCX384", lat: Double, lon: Double, track: Double?,
                        alt: Int = 38_000, gs: Double = 450, vr: Double = 0) -> Flight {
        let trackJSON = track.map { "\"track\":\($0)," } ?? ""
        let json = """
        {"hex":"abc123","flight":"\(callsign)","t":"B738","alt_baro":\(alt),"gs":\(gs),\(trackJSON)
         "lat":\(lat),"lon":\(lon),"dst":10,"dir":90,"baro_rate":\(vr)}
        """
        return Flight(adsb: try! JSONDecoder().decode(ADSBAircraft.self, from: Data(json.utf8)))!
    }

    private let oak = Airport(code: "OAK", city: "Oakland", lat: 37.72, lon: -122.22)
    private let lax = Airport(code: "LAX", city: "Los Angeles", lat: 33.94, lon: -118.41)
    private let rsw = Airport(code: "RSW", city: "Fort Myers", lat: 26.54, lon: -81.76)
    private let msp = Airport(code: "MSP", city: "Minneapolis", lat: 44.88, lon: -93.22)

    // MARK: Route verification

    func testRejectsRouteFarFromAircraft() {
        // A stale OAK→LAX route for an aircraft over Tennessee.
        let f = flight(lat: 36.0, lon: -88.2, track: 330)
        XCTAssertFalse(FlightService.isPlausible(RouteInfo(from: oak, to: lax), for: f))
    }

    func testAcceptsRouteAlongPath() {
        // RSW→MSP passing over Tennessee, heading north-west.
        let f = flight(lat: 36.0, lon: -88.2, track: 330)
        XCTAssertTrue(FlightService.isPlausible(RouteInfo(from: rsw, to: msp), for: f))
    }

    func testRejectsRouteWhenFlyingAwayFromDestination() {
        let f = flight(lat: 36.0, lon: -88.2, track: 150)   // heading south-east, away from MSP
        XCTAssertFalse(FlightService.isPlausible(RouteInfo(from: rsw, to: msp), for: f))
    }

    func testProgressAlongRoute() throws {
        var f = flight(lat: 36.0, lon: -88.2, track: 330)
        XCTAssertNil(f.progress)
        f.route = RouteInfo(from: rsw, to: msp)
        let p = try XCTUnwrap(f.progress)
        XCTAssertGreaterThan(p, 0.4); XCTAssertLessThan(p, 0.75)   // Tennessee is past halfway RSW→MSP
        f.lat = rsw.lat; f.lon = rsw.lon
        XCTAssertEqual(try XCTUnwrap(f.progress), 0, accuracy: 0.01)
    }

    func testAcceptsAnythingNearAirport() {
        let f = flight(lat: 44.80, lon: -93.10, track: 90, alt: 3000)  // manoeuvring near MSP
        XCTAssertTrue(FlightService.isPlausible(RouteInfo(from: rsw, to: msp), for: f))
    }

    // MARK: Dead reckoning

    func testProjectionMovesAlongTrack() {
        // 360 kt due north for 60 s = 6 nm ≈ 0.1° latitude.
        let f = flight(lat: 40, lon: -88, track: 0, gs: 360, vr: 1200)
        let p = f.projected(by: 60, observerLat: 40, observerLon: -88)
        XCTAssertEqual(p.lat, 40.1, accuracy: 0.002)
        XCTAssertEqual(p.lon, -88, accuracy: 0.001)
        XCTAssertEqual(p.distance, 6, accuracy: 0.05)
        XCTAssertEqual(p.altitude, 38_000 + 1200)
        XCTAssertEqual(p.direction, "N")
    }

    func testProjectionWithoutTrackIsIdentity() {
        let f = flight(lat: 40, lon: -88, track: nil)
        XCTAssertEqual(f.projected(by: 60, observerLat: 40, observerLon: -88), f)
    }

    // MARK: Parsing & formatting

    func testGroundTrafficIsDropped() {
        let json = #"{"hex":"abc","alt_baro":"ground","lat":1,"lon":1,"dst":1}"#
        XCTAssertNil(Flight(adsb: try! JSONDecoder().decode(ADSBAircraft.self, from: Data(json.utf8))))
    }

    func testAirlineCallsignHeuristic() {
        XCTAssertTrue(flight(callsign: "DAL1342", lat: 0, lon: 0, track: 0).looksLikeAirline)
        XCTAssertFalse(flight(callsign: "N172SP", lat: 0, lon: 0, track: 0).looksLikeAirline)
    }

    func testUnitFormatting() {
        var o = DisplayOptions()
        XCTAssertEqual(o.distance(10), "10.0NM")
        XCTAssertEqual(o.speed(100), "100KT")
        o.units = .metric
        XCTAssertEqual(o.distance(10), "18.5KM")
        XCTAssertEqual(o.speed(100), "185KMH")
        XCTAssertEqual(o.altitude(10_000), "3,048M")
        o.style = .standard
        XCTAssertEqual(o.altitude(10_000), "3,048 m")
        XCTAssertEqual(o.speed(100), "185 km/h")
    }

    func testSettingsDecodeToleratesMissingAndUnknownKeys() throws {
        let old = #"{"radius":"100","display":{"theme":"green","bogus":1},"widgetRefreshMinutes":2}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.radius, .nm100)
        XCTAssertEqual(s.display.theme, .green)
        XCTAssertEqual(s.display.style, .led)
        XCTAssertEqual(s.widgetRefreshSeconds, 30)
    }

    func testLegacyGlassStyleLoadsAsStandard() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"display":{"style":"glass"}}"#.utf8))
        XCTAssertEqual(s.display.style, .standard)
    }
}
