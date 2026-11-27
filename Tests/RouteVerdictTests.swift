import XCTest

/// Route plausibility, the shared route resolver, and route corrections (storage, expiry and how
/// enrichment applies them).
final class RouteVerdictTests: XCTestCase {

    private func flight(hex: String = "abc123", callsign: String = "DAL2855", lat: Double, lon: Double,
                        track: Double, alt: Int = 39_000, vr: Double = 0) -> Flight {
        let json = """
        {"hex":"\(hex)","flight":"\(callsign)","t":"A321","alt_baro":\(alt),"gs":460,"track":\(track),
         "lat":\(lat),"lon":\(lon),"dst":10,"dir":90,"baro_rate":\(vr)}
        """
        return Flight(adsb: try! JSONDecoder().decode(ADSBAircraft.self, from: Data(json.utf8)))!
    }

    private let msp = Airport(code: "MSP", city: "Minneapolis", lat: 44.88, lon: -93.22)
    private let bna = Airport(code: "BNA", city: "Nashville", lat: 36.12, lon: -86.68)
    private let slc = Airport(code: "SLC", city: "Salt Lake City", lat: 40.79, lon: -111.98)
    private var stale: RouteInfo { RouteInfo(airline: "Delta Air Lines", flightNo: "DL2855", airlineCode: "DL", from: msp, to: bna) }

    /// Near Rockford, IL: about 240 nm from MSP and 380 nm from BNA, BNA bearing ~162°.
    private let rockford = (lat: 42.2, lon: -89.1)

    // MARK: Plausibility

    func testCruiseFarFromBothAirportsNeedsCloseHeading() {
        // DAL2855: stale MSP→BNA, aircraft heading 093° at FL390 (69° off the bearing to BNA).
        let cruise = flight(lat: rockford.lat, lon: rockford.lon, track: 93)
        XCTAssertFalse(FlightService.isPlausible(stale, for: cruise))
        // The same geometry below cruise keeps the looser 100° tolerance (vectors, climb-out).
        XCTAssertTrue(FlightService.isPlausible(stale, for: flight(lat: rockford.lat, lon: rockford.lon, track: 93, alt: 12_000)))
        // On course in cruise is fine.
        XCTAssertTrue(FlightService.isPlausible(stale, for: flight(lat: rockford.lat, lon: rockford.lon, track: 160)))
    }

    func testDetourRuleStillApplies() {
        // Far off the MSP→BNA path, even heading straight at BNA.
        XCTAssertFalse(FlightService.isPlausible(stale, for: flight(lat: 40.0, lon: -100.0, track: 105, alt: 20_000)))
    }

    func testAngleBetweenWrapsAround() {
        XCTAssertEqual(FlightService.angleBetween(350, 10), 20, accuracy: 1e-9)
        XCTAssertEqual(FlightService.angleBetween(10, 190), 180, accuracy: 1e-9)
        XCTAssertEqual(FlightService.angleBetween(93, 162), 69, accuracy: 1e-9)
    }

    // MARK: Resolver

    func testRecordedDepartureOverridesStaleScheduleThatLooksPlausible() {
        // Heading 115°: only 47° off BNA, so the stale route passes the geometric check alone.
        let f = flight(lat: rockford.lat, lon: rockford.lon, track: 115)
        XCTAssertEqual(RouteResolver.resolve(scheduled: stale, flight: f, departedFrom: nil).route, stale)
        let r = RouteResolver.resolve(scheduled: stale, flight: f, departedFrom: slc)
        XCTAssertNil(r.route, "cruising: no destination to estimate")
        XCTAssertNil(r.situation)
        XCTAssertEqual(r.note, "The scheduled route (MSP → BNA) doesn’t match the recorded track. Origin from the recorded track.")
    }

    func testContradictedScheduleWithDescentEstimatesDestinationAndClaimsNoDiversion() throws {
        // Departed SLC (track), stale MSP→BNA, descending toward Chicago O'Hare from the west.
        let f = flight(lat: 41.95, lon: -88.6, track: 90, alt: 9_000, vr: -1_800)
        let r = RouteResolver.resolve(scheduled: stale, flight: f, departedFrom: slc)
        XCTAssertEqual(r.route?.from.code, "SLC")
        XCTAssertEqual(r.route?.flightNo, "DL2855", "keeps the airline and number")
        XCTAssertTrue(r.destinationEstimated)
        XCTAssertNil(r.situation, "a known-invalid schedule never becomes a diversion")
        XCTAssertNotEqual(try XCTUnwrap(r.route?.to.code), "BNA")
    }

    func testMatchingDepartureConfirmsSchedule() {
        let f = flight(lat: rockford.lat, lon: rockford.lon, track: 160)
        XCTAssertEqual(RouteResolver.resolve(scheduled: stale, flight: f, departedFrom: msp), RouteResolution(route: stale))
        XCTAssertNil(RouteResolver.correction(departedFrom: msp, scheduled: stale, hex: "ABC123"))
        XCTAssertEqual(RouteResolver.correction(departedFrom: slc, scheduled: stale, hex: "ABC123", now: .distantPast),
                       RouteCorrection(hex: "abc123", origin: slc, at: .distantPast))
    }

    func testDepartureNeedsALowStart() throws {
        let t = Date()
        let low = try XCTUnwrap(FlightTrack(waypoints: [[t.timeIntervalSince1970 - 3_600, 40.79, -111.97, 300.0],
                                                       [t.timeIntervalSince1970 - 60, 42.2, -89.1, 11_000.0]],
                                            current: nil, now: t))
        XCTAssertEqual(RouteResolver.departure(of: low)?.airport.code, "SLC")
        var high = low
        high.points[0].altitudeFt = 30_000
        XCTAssertNil(RouteResolver.departure(of: high), "a track picked up in cruise says nothing about the origin")
    }

    // MARK: Corrections: storage, merge and expiry

    func testCorrectionAppliesOnlyToSameAircraftWithinLifetime() {
        let c = RouteCorrection(hex: "abc123", origin: slc, at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(c.applies(to: "ABC123", now: Date(timeIntervalSince1970: 11 * 3_600)))
        XCTAssertFalse(c.applies(to: "def456", now: Date(timeIntervalSince1970: 60)), "another airframe is another flight")
        XCTAssertFalse(c.applies(to: "abc123", now: Date(timeIntervalSince1970: 13 * 3_600)), "expired")
    }

    func testMergeKeepsNewerCorrectionAndPruneDropsExpired() {
        let now = Date()
        var a = LookupCache.Store(), b = LookupCache.Store()
        a.corrections["DAL1"] = RouteCorrection(hex: "abc123", origin: slc, at: now)
        b.corrections["DAL1"] = RouteCorrection(hex: "abc123", origin: msp, at: now.addingTimeInterval(-60))
        b.corrections["DAL2"] = RouteCorrection(hex: "def456", origin: msp, at: now.addingTimeInterval(-13 * 3_600))
        let merged = LookupCache.merge(a, b)
        XCTAssertEqual(merged.corrections["DAL1"]?.origin.code, "SLC")
        XCTAssertEqual(LookupCache.merge(b, a).corrections["DAL1"]?.origin.code, "SLC", "order doesn't matter")
        let pruned = LookupCache.pruned(merged, now: now)
        XCTAssertEqual(Set(pruned.corrections.keys), ["DAL1"])
    }

    func testOldCacheFilesStillDecode() throws {
        let old = #"{"routes":{"DAL1":{"at":0}},"aircraft":{}}"#
        let store = try JSONDecoder().decode(LookupCache.Store.self, from: Data(old.utf8))
        XCTAssertEqual(store.routes.count, 1)
        XCTAssertTrue(store.corrections.isEmpty)
    }

    func testCorrectionWrittenByOneProcessIsSeenByAnother() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lookup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let widget = LookupCache(url: url), app = LookupCache(url: url)
        // The widget has already loaded the (empty) file before the app learns the correction.
        let before = await widget.correction(callsign: "DAL2855", hex: "abc123")
        XCTAssertNil(before)
        let c = RouteCorrection(hex: "abc123", origin: slc, at: Date())
        let first = await app.record(correction: c, for: "DAL2855")
        let again = await app.record(correction: c, for: "DAL2855")
        XCTAssertTrue(first)
        XCTAssertFalse(again, "the same verdict isn't news")
        await app.save()
        let seen = await widget.correction(callsign: "dal2855 ", hex: "ABC123")
        XCTAssertEqual(seen?.origin.code, "SLC")
    }

    // MARK: Enrichment applies corrections and cached tracks (no network)

    /// A fresh aircraft and callsign, as the shared cache persists between test runs.
    private func uniqueFlight() -> (hex: String, callsign: String) {
        (String(format: "%06x", Int.random(in: 0..<0xFFFFFF)), "TST\(Int.random(in: 10_000...99_999))")
    }

    func testVerifiedRouteAppliesStoredCorrection() async {
        let (hex, callsign) = uniqueFlight()
        let f = flight(hex: hex, callsign: callsign, lat: rockford.lat, lon: rockford.lon, track: 115)
        let before = await FlightService.verifiedRoute(stale, for: f)
        XCTAssertEqual(before.route, stale, "no verdict yet: the stale route fits the geometry")
        await LookupCache.shared.record(correction: RouteCorrection(hex: hex, origin: slc, at: Date()), for: callsign)
        let after = await FlightService.verifiedRoute(stale, for: f)
        XCTAssertNil(after.route, "list, panel and widget now agree with the detail")
    }

    func testVerifiedRouteUsesCachedTrackAndLearnRouteStoresIt() async throws {
        let (hex, callsign) = uniqueFlight()
        let now = Date().timeIntervalSince1970
        let json = """
        {"icao24":"\(hex)","path":[[\(now - 7_200),40.79,-111.97,300,90,false],[\(now - 3_600),41.5,-100.0,11800,90,false],
         [\(now - 60),42.2,-89.2,11880,93,false]]}
        """
        TrackCache.store(Data(json.utf8), for: hex)
        let f = flight(hex: hex, callsign: callsign, lat: rockford.lat, lon: rockford.lon, track: 115)
        let r = await FlightService.verifiedRoute(stale, for: f)
        XCTAssertNil(r.route, "the cached track shows it left SLC, not MSP")

        let track = try XCTUnwrap(TrackCache.track(hex: hex, current: f.geoPoint))
        let learned = await FlightService.learnRoute(from: track, for: f, scheduled: stale)
        let relearned = await FlightService.learnRoute(from: track, for: f, scheduled: stale)
        XCTAssertTrue(learned)
        XCTAssertFalse(relearned)
        let stored = await LookupCache.shared.correction(callsign: callsign, hex: hex)
        XCTAssertEqual(stored?.origin.code, "SLC")
    }

    func testMergeKeepsKnownRouteDuringDiversion() {
        var known = flight(lat: rockford.lat, lon: rockford.lon, track: 300, alt: 9_000, vr: -1_500)
        known.route = stale
        known.pathSituation = .diverting(to: slc, scheduled: bna)
        let live = flight(lat: rockford.lat, lon: rockford.lon, track: 300, alt: 9_000, vr: -1_500)
        XCTAssertFalse(FlightService.isPlausible(stale, for: live), "flying away from BNA")
        let merged = FlightListFilter.merging([live], known: [live.id: known])
        XCTAssertEqual(merged[0].route, stale)
        XCTAssertEqual(merged[0].pathSituation, known.pathSituation)
    }
}
