import XCTest

/// Diversion, return, emergency and holding detection (uses the bundled airport table).
final class FlightSituationTests: XCTestCase {

    private func flight(lat: Double, lon: Double, track: Double, alt: Int, vr: Double, squawk: String? = nil) -> Flight {
        let code = squawk.map { ",\"squawk\":\"\($0)\"" } ?? ""
        let json = """
        {"hex":"abc123","flight":"UAL1189","t":"B39M","alt_baro":\(alt),"gs":300,"track":\(track),
         "lat":\(lat),"lon":\(lon),"dst":10,"dir":90,"baro_rate":\(vr)\(code)}
        """
        return Flight(adsb: try! JSONDecoder().decode(ADSBAircraft.self, from: Data(json.utf8)))!
    }

    private let ord = Airport(code: "ORD", city: "Chicago", lat: 41.98, lon: -87.90)
    private let den = Airport(code: "DEN", city: "Denver", lat: 39.86, lon: -104.67)
    private let oak = Airport(code: "OAK", city: "Oakland", lat: 37.72, lon: -122.22)
    private let lax = Airport(code: "LAX", city: "Los Angeles", lat: 33.94, lon: -118.41)
    private var ordDen: RouteInfo { RouteInfo(airline: "United Airlines", flightNo: "UA1189", from: ord, to: den) }

    func testAirportTableIsBundled() {
        XCTAssertGreaterThan(AirportDB.all.count, 3_000)
        XCTAssertEqual(AirportDB.nearest(to: GeoPoint(lat: 41.98, lon: -87.91), within: 8)?.code, "ORD")
    }

    // MARK: Diverting

    func testDescendingTowardAnotherAirportAlongTheRouteIsADiversion() {
        // ORD→DEN, 84 nm out of Chicago, turned north and descending toward Madison.
        let f = flight(lat: 42.6, lon: -89.6, track: 19, alt: 9_000, vr: -1_600)
        let s = FlightSituation.path(for: f, route: ordDen)
        XCTAssertEqual(s, .diverting(to: AirportDB.nearest(to: GeoPoint(lat: 43.14, lon: -89.34), within: 2)!, scheduled: den))
        XCTAssertEqual(s?.tag, "DIVERT MSN")
        XCTAssertEqual(s?.title, "Diverting to MSN")
        XCTAssertEqual(s?.spoken, "Diverting to Madison (MSN) instead of Denver (DEN)")
        XCTAssertEqual(s?.severity, .caution)
    }

    func testDiversionKeepsRouteEvenWhenItFailsPlausibility() {
        // Heading away from Denver: the geometric check alone would drop the route.
        let f = flight(lat: 42.6, lon: -89.6, track: 19, alt: 9_000, vr: -1_600)
        XCTAssertFalse(FlightService.isPlausible(ordDen, for: f))
        let r = RouteResolver.resolve(scheduled: ordDen, flight: f, departedFrom: nil)
        XCTAssertEqual(r.route, ordDen)
        var shown = f
        shown.route = r.route
        shown.pathSituation = r.situation
        XCTAssertEqual(shown.destination?.code, "MSN")
        XCTAssertEqual(BoardFormat.route(shown), "ORD›MSN")
        XCTAssertEqual(FlightRowText.subtitle(shown), "ORD → MSN · B39M")
    }

    func testNormalArrivalIsNotADiversion() {
        // 30 nm east of Denver, descending toward it.
        let f = flight(lat: 39.9, lon: -104.0, track: 265, alt: 9_000, vr: -1_500)
        XCTAssertNil(FlightSituation.path(for: f, route: ordDen))
    }

    func testStepDownDescentTowardTheDestinationIsNotADiversion() {
        // 140 nm short of Denver at 14,000 ft and still heading for it.
        let f = flight(lat: 40.0, lon: -101.7, track: 262, alt: 14_000, vr: -1_200)
        XCTAssertNil(FlightSituation.path(for: f, route: ordDen))
    }

    func testCruiseAndLevelFlightAreNeverUnusual() {
        XCTAssertNil(FlightSituation.path(for: flight(lat: 42.6, lon: -89.6, track: 19, alt: 36_000, vr: -1_600), route: ordDen))
        XCTAssertNil(FlightSituation.path(for: flight(lat: 42.6, lon: -89.6, track: 19, alt: 9_000, vr: 0), route: ordDen))
    }

    func testStaleRouteForAnotherLegIsNotADiversion() {
        // A stale OAK→LAX schedule for an aircraft descending into Nashville.
        let f = flight(lat: 36.3, lon: -87.1, track: 120, alt: 9_000, vr: -1_500)
        XCTAssertNil(FlightSituation.path(for: f, route: RouteInfo(from: oak, to: lax)))
    }

    // MARK: Returning

    func testConfirmedOriginAndHeadingBackIsAReturn() {
        // ORD→DEN, 58 nm west of O'Hare, descending eastbound back toward it.
        let f = flight(lat: 41.95, lon: -89.2, track: 92, alt: 10_000, vr: -1_500)
        XCTAssertEqual(FlightSituation.path(for: f, route: ordDen, departedFrom: ord), .returning(to: ord))
        let r = RouteResolver.resolve(scheduled: ordDen, flight: f, departedFrom: ord)
        var shown = f
        shown.route = r.route
        shown.pathSituation = r.situation
        XCTAssertEqual(shown.situation?.tag, "RETURN ORD")
        XCTAssertNil(shown.progress, "no progress bar while going back")
        XCTAssertEqual(BoardFormat.route(shown), "RTN›ORD")
    }

    func testHeadingTowardOriginWithoutConfirmationClaimsNothing() {
        // Usually a stale schedule for the opposite leg, so neither a return nor a diversion.
        let f = flight(lat: 41.95, lon: -89.2, track: 92, alt: 10_000, vr: -1_500)
        XCTAssertNil(FlightSituation.path(for: f, route: ordDen))
    }

    // MARK: Emergencies

    func testSquawksOutrankRouteSituations() {
        var f = flight(lat: 42.6, lon: -89.6, track: 19, alt: 9_000, vr: -1_600, squawk: "7700")
        f.pathSituation = .diverting(to: ord, scheduled: den)
        XCTAssertEqual(f.situation, .emergency(squawk: "7700"))
        XCTAssertEqual(f.situation?.severity, .critical)
        XCTAssertEqual(f.situation?.title, "Emergency · 7700")
        f.squawk = "7500"
        XCTAssertEqual(f.situation?.tag, "HIJACK")
        f.squawk = "7600"
        XCTAssertEqual(f.situation, .radioFailure)
        XCTAssertEqual(f.situation?.severity, .caution)
        f.squawk = "2000"
        XCTAssertEqual(f.situation, .diverting(to: ord, scheduled: den))
    }

    func testFlightsCachedByOlderVersionsDecode() throws {
        let old = #"{"id":"abc123","callsign":"UAL1","reg":"N1","typeCode":"B738","altitude":1000,"verticalRate":0,"speed":200,"#
            + #""lat":1,"lon":2,"distance":3,"bearing":4}"#
        let f = try JSONDecoder().decode(Flight.self, from: Data(old.utf8))
        XCTAssertNil(f.pathSituation)
        var diverting = f
        diverting.pathSituation = .diverting(to: ord, scheduled: den)
        let round = try JSONDecoder().decode(Flight.self, from: JSONEncoder().encode(diverting))
        XCTAssertEqual(round.pathSituation, diverting.pathSituation)
    }

    // MARK: Spotter rule

    func testDiversionAlertRuleIsOnByDefaultAndLabelled() {
        var f = flight(lat: 42.6, lon: -89.6, track: 19, alt: 9_000, vr: -1_600)
        f.pathSituation = FlightSituation.path(for: f, route: ordDen)
        var s = SpotterSettings()
        s.emergencies = false
        XCTAssertTrue(s.activeRules.contains(.diversion))
        let alerts = SpotterEngine.evaluate([f], settings: s, db: nil, squawk: \.squawk)
        XCTAssertEqual(alerts.map(\.rule), [.diversion])
        XCTAssertEqual(alerts.first?.title, "Diverting to Madison (MSN)")
        s.diversions = false
        XCTAssertTrue(SpotterEngine.evaluate([f], settings: s, db: nil, squawk: \.squawk).isEmpty)
        // Deduplicated like other rules.
        var ledger = AlertLedger()
        let now = Date()
        XCTAssertEqual(ledger.admit(alerts, now: now).count, 1)
        XCTAssertTrue(ledger.admit(alerts, now: now.addingTimeInterval(60)).isEmpty)
    }

    func testMenuBarReadoutNotesTheSituation() {
        var f = flight(lat: 42.6, lon: -89.6, track: 19, alt: 9_000, vr: -1_600)
        f.pathSituation = .diverting(to: ord, scheduled: den)
        let raw = flight(lat: 42.6, lon: -89.6, track: 19, alt: 9_000, vr: -1_600)
        XCTAssertEqual(MenuBarReadout.text(flights: [raw], known: [f], display: DisplayOptions()), "UAL1189 · 10.0 nm · DIVERT ORD")
    }

    // MARK: Holding

    func testOrbitIsHoldingAndStraightFlightIsNot() {
        let now = Date()
        let centre = GeoPoint(lat: 40, lon: -100)
        let circle = FlightMath.circle(around: centre, radiusNM: 3, count: 16)
        let orbit = (0...16).map { i in TimedPoint(point: circle[i % 16], time: now.addingTimeInterval(Double(i - 16) * 25)) }
        XCTAssertTrue(FlightSituation.isHolding(trail: orbit, now: now))
        let straight = (0..<16).map { i in TimedPoint(point: GeoPoint(lat: 40, lon: -100 + Double(i) * 0.05), time: now.addingTimeInterval(Double(i - 16) * 25)) }
        XCTAssertFalse(FlightSituation.isHolding(trail: straight, now: now))
        // The same orbit flown more than 8 minutes ago doesn't count.
        XCTAssertFalse(FlightSituation.isHolding(trail: orbit, now: now.addingTimeInterval(9 * 60)))
    }
}
