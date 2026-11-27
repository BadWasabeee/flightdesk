import XCTest

/// Routes decoded from ACARS: coordinate formats, wind requests, flight plans and position reports
/// (real messages from the Airframes.io feed, November 2026), placing names with a small fixture
/// navigation table, merging successive messages and the part of the route still ahead.
final class AcarsRouteTests: XCTestCase {

    private let sent = try! Date("2026-11-27T03:51:20.000Z", strategy: .iso8601)

    /// Real coordinates from the bundled table, including same-named navaids on other continents.
    private let navDB = NavDB(csv: """
        # fixture
        SLATN,39.1167,-67,F
        SOORY,38.5,-60.2676,F
        STG,42.9269,-8.4254,V
        STG,8.0887,-80.9402,V
        STG,-22.0331,-41.0742,N
        STG,61.8609,6.3676,N
        ZMR,41.5302,-5.6397,V
        ZMR,45.6247,-74.0881,N
        PDT,40.2529,-3.348,V
        PDT,45.6984,-118.9387,V
        PTC,39.4273,3.2567,N
        PTC,6.1817,-67.496,V
        BRTMN,42.4738,-87.8052,F
        TAAYZ,42.7255,-87.8214,F
        PETTY,42.8274,-87.6339,F
        bad row
        """)

    private let jfk = GeoPoint(lat: 40.6398, lon: -73.7789)
    private let palma = GeoPoint(lat: 39.5517, lon: 2.7388)

    private let transatlantic = "REQPWI/WQ370.380.390.400:N39539W071575.SLATN.SOORY.N40W050.N40W040.N42W030.N44W020.MUDOS.STG.DESAT.ZMR.PDT.AKOKI.NANDO.MINGU.ABOSI.MABUX.RETBA.MOPIR.LASPO.ORVUS.GODOX.EDULI.PTC.SOTAX.RISEP.ETOIL.XATOS.IBREP"

    private func names(_ r: AcarsRouteReport?) -> [String] { r?.waypoints.map(\.name) ?? [] }

    private func assertPoint(_ p: GeoPoint?, _ lat: Double, _ lon: Double, file: StaticString = #filePath, line: UInt = #line) {
        guard let p else { return XCTFail("no point", file: file, line: line) }
        XCTAssertEqual(p.lat, lat, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(p.lon, lon, accuracy: 1e-6, file: file, line: line)
    }

    // MARK: Coordinates

    func testCoordinateFormats() {
        func c(_ s: String) -> GeoPoint? { AcarsRouteParser.coordinate(s[...]) }
        assertPoint(c("N40W050"), 40, -50)
        assertPoint(c("S10W169"), -10, -169)
        assertPoint(c("N39539W071575"), 39 + 53.9 / 60, -(71 + 57.5 / 60))
        assertPoint(c("S05000W165000"), -5, -165)
        assertPoint(c("S27491E153026"), -(27 + 49.1 / 60), 153 + 2.6 / 60)
        // ARINC 424 names, checked against the coordinates flight plans send with them
        // ("52N00,N52000W100000", "5290N,N52000W090000") and the quadrant letters.
        assertPoint(c("4550N"), 45, -50)
        assertPoint(c("52N00"), 52, -100)
        assertPoint(c("5290N"), 52, -90)
        assertPoint(c("5040E"), 50, 40)
        assertPoint(c("50E40"), 50, 140)
        assertPoint(c("5040S"), -50, 40)
        assertPoint(c("50W40"), -50, -140)
        // Unverified or invalid forms are rejected rather than guessed.
        XCTAssertNil(c("N40083W07428"))     // 12 characters: minutes without tenths, or cut off?
        XCTAssertNil(c("H4540"))
        XCTAssertNil(c("N39609W071575"))    // 60.9 minutes
        XCTAssertNil(c("N95W050"))
        XCTAssertNil(c("5040X"))
        XCTAssertNil(c("SLATN"))
    }

    func testRouteElements() {
        XCTAssertEqual(AcarsRouteParser.token("SLATN"), RouteToken(name: "SLATN", point: nil, isCoordinate: false))
        XCTAssertEqual(AcarsRouteParser.token("SEFFY,N51234W107083")?.isCoordinate, false)
        assertPoint(AcarsRouteParser.token("SEFFY,N51234W107083")?.point, 51 + 23.4 / 60, -(107 + 8.3 / 60))
        for skipped in ["Q961", "J22", "SERFR4", "SXC-M150", "BAD02", "LLS01", "SEFFY,N5123", "TOOLONG", "a"] {
            XCTAssertNil(AcarsRouteParser.token(skipped[...]), skipped)
        }
    }

    // MARK: Messages

    func testWindRequestKeepsCoordinatesAndDropsAPossiblyCutLastName() throws {
        let r = try XCTUnwrap(AcarsRouteParser.report(in: transatlantic, sent: sent))
        XCTAssertEqual(r.kind, .windRequest)
        XCTAssertTrue(r.reachesDestination)
        XCTAssertEqual(r.waypoints.count, 28)
        XCTAssertEqual(r.waypoints.first?.isCoordinate, true)
        XCTAssertEqual(r.waypoints.last?.name, "XATOS")   // IBREP runs to the end of the text
        XCTAssertEqual(Array(names(r)[1...6]), ["SLATN", "SOORY", "N40W050", "N40W040", "N42W030", "N44W020"])
    }

    func testWindRequestStopsAtTheRunway() {
        // Real request (A11F59): after the destination runway come two points that aren't route.
        let core = "REQPWI/TS040442,271126/WQ390.340.300.240:N40083W07428.N41139W069484.VITOL.PORTI.N47W050.N48W040.N49W030.N50W020.SOMAX.ATSUR.ARKIL.SIDDI.DAWLY.ELRIP.OTMET.SOKDU.NEDUL.BEGTO.HAZEL.LLS01.OCK.N51208W00039.D287L.GWC35.CF09L.FF09L.RW09L.N49472W033053.N47472W033053/DQ370078E"
        let r = AcarsRouteParser.report(in: core, sent: sent)
        XCTAssertEqual(names(r), ["N41139W069484", "VITOL", "PORTI", "N47W050", "N48W040", "N49W030", "N50W020", "SOMAX", "ATSUR",
                                  "ARKIL", "SIDDI", "DAWLY", "ELRIP", "OTMET", "SOKDU", "NEDUL", "BEGTO", "HAZEL", "OCK"])
        XCTAssertNil(AcarsRouteParser.report(in: "REQPWI/WQ350:", sent: sent))
    }

    func testFlightPlans() throws {
        // Route after F:, running to the end (its last element carries the check sequence).
        let sofia = AcarsRouteParser.report(in: "FPN/FNWZZ4ZH/RI:DA:LBSF:AA:EPWA:F:OGOTA.N133..LOMOS..NARKA..LENOV..ORTEB..KONZI..LOGDA853E", sent: sent)
        XCTAssertEqual(sofia?.kind, .flightPlan)
        XCTAssertEqual(names(sofia), ["OGOTA", "LOMOS", "NARKA", "LENOV", "ORTEB", "KONZI"])
        // Route straight after RP, ending at the next key, with fixes sent with their coordinates.
        let brisbane = try XCTUnwrap(AcarsRouteParser.report(in: "FPN/FNVOZ1641/RP..SANEG,S27491E153026.H91.ADMAR.Q78.OLTIN.H201.TESAT.H65.WOL.H20.OTKED.J22.LT:DA:YBBN:AA:YMLT229C", sent: sent))
        XCTAssertEqual(names(brisbane), ["SANEG", "ADMAR", "OLTIN", "TESAT", "WOL", "OTKED", "LT"])
        assertPoint(brisbane.waypoints[0].point, -(27 + 49.1 / 60), 153 + 2.6 / 60)
        let calgary = try XCTUnwrap(AcarsRouteParser.report(in: "FPN/RP:DA:CYYC:AA:CYHZ:F:LOMLO,N51042W113232.Q961.DAPOP..SEFFY,N51234W107083..52N00,N52000W100000..5290N,N52000W090000..MOGAG,N51157W082158..MOFAT,N49108W073000..OMVEV,N46020W0654722104", sent: sent))
        XCTAssertEqual(names(calgary), ["LOMLO", "DAPOP", "SEFFY", "52N00", "5290N", "MOGAG", "MOFAT"])
        XCTAssertEqual(calgary.waypoints[3].isCoordinate, true)
        XCTAssertNil(calgary.waypoints[1].point)
        XCTAssertNil(AcarsRouteParser.report(in: "FPN/FNABC123/XX:1", sent: sent))
    }

    func testPositionReport() throws {
        let r = try XCTUnwrap(AcarsRouteParser.report(in: "POSN42285W087484,BRTMN,035113,174,TAAYZ,035331,PETTY,M15,06645,130641CE", sent: sent))
        XCTAssertEqual(r.kind, .position)
        XCTAssertFalse(r.reachesDestination)
        assertPoint(r.position?.point, 42 + 28.5 / 60, -(87 + 48.4 / 60))
        XCTAssertEqual(r.position?.time, try Date("2026-11-27T03:51:13.000Z", strategy: .iso8601))
        XCTAssertEqual(names(r), ["TAAYZ", "PETTY"])
        // Fixes sent as coordinates; a report time just before midnight belongs to the day before.
        let late = try Date("2026-11-27T00:00:20.000Z", strategy: .iso8601)
        let c = try XCTUnwrap(AcarsRouteParser.report(in: "POSN41051W073011,NEWES,235957,251,N41094W072522,035811,RUIZE,M24,19764,190/TS035707,27112621C9", sent: late))
        XCTAssertEqual(names(c), ["N41094W072522", "RUIZE"])
        XCTAssertEqual(c.position?.time, try Date("2026-11-26T23:59:57.000Z", strategy: .iso8601))
        // Place/bearing/distance points aren't fixes; a fix in the last field may be cut off.
        XCTAssertEqual(names(AcarsRouteParser.report(in: "POSN33284W119209,GALIP,040136,223,SXC-M150,040628,SXC,M21,35226,104", sent: sent)), ["SXC"])
        XCTAssertEqual(names(AcarsRouteParser.report(in: "POSN33284W119209,GALIP,040136,223,SXC,040628,SLAER", sent: sent)), ["SXC"])
        XCTAssertNil(AcarsRouteParser.report(in: "POSN4228W087484,BRTMN,035113", sent: sent))
    }

    // MARK: Placing names

    func testTransatlanticRouteIsPlacedAlongTheCorridor() throws {
        let report = try XCTUnwrap(AcarsRouteParser.report(in: transatlantic, sent: sent))
        let context = AcarsRouteContext(origin: jfk, destination: palma)
        let route = try XCTUnwrap(AcarsRouteResolver.route(from: [report], context: context, navDB: navDB))
        let byName = Dictionary(route.waypoints.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        assertPoint(byName["N40W040"]?.point, 40, -40)
        assertPoint(byName["SLATN"]?.point, 39.1167, -67)
        assertPoint(byName["STG"]?.point, 42.9269, -8.4254)      // Santiago, not Panama, Brazil or Norway
        assertPoint(byName["ZMR"]?.point, 41.5302, -5.6397)      // Zamora VOR, not the Canadian NDB
        assertPoint(byName["PDT"]?.point, 40.2529, -3.348)       // Spain, not Pendleton
        assertPoint(byName["PTC"]?.point, 39.4273, 3.2567)
        XCTAssertNil(byName["MUDOS"]?.point)                     // not in the table: kept, unplaced
        XCTAssertEqual(route.waypoints.map(\.name), report.waypoints.map(\.name))
        XCTAssertEqual(route.resolvedCount, 11)
        XCTAssertEqual(byName["N40W050"]?.label, "40N 50W")
        XCTAssertEqual(route.waypoints[0].label, "39.9N 72.0W")
    }

    func testSameNameIsPlacedNearTheRouteWithoutACorridor() throws {
        // No origin or destination: the neighbours decide.
        let report = try XCTUnwrap(AcarsRouteParser.report(in: "REQPWI/WQ390:N44W020.STG.ZMR.PDT.X/DQ", sent: sent))
        let route = try XCTUnwrap(AcarsRouteResolver.route(from: [report], context: AcarsRouteContext(), navDB: navDB))
        assertPoint(route.waypoints[1].point, 42.9269, -8.4254)
        assertPoint(route.waypoints[3].point, 40.2529, -3.348)
    }

    func testFarCandidatesAreRejected() throws {
        // Only the US PDT exists here: it's thousands of miles off the JFK–Palma corridor.
        let usOnly = NavDB([NavPoint(ident: "PDT", point: GeoPoint(lat: 45.6984, lon: -118.9387), kind: .vhf)])
        let tokens = [RouteToken(name: "N44W020", point: GeoPoint(lat: 44, lon: -20), isCoordinate: true),
                      RouteToken(name: "PDT", point: nil, isCoordinate: false)]
        let placed = AcarsRouteResolver.resolve(tokens, from: nil, context: AcarsRouteContext(origin: jfk, destination: palma), navDB: usOnly)
        XCTAssertNil(placed[1].point)
        // Without a corridor, a leg far longer than any route leg is rejected too.
        let alone = AcarsRouteResolver.resolve(tokens, from: nil, context: AcarsRouteContext(), navDB: usOnly)
        XCTAssertNil(alone[1].point)
    }

    // MARK: Merging and progress

    func testPositionReportUpdatesTheRouteAheadAndKeepsTheRest() throws {
        let wind = try XCTUnwrap(AcarsRouteParser.report(in: "REQPWI/WQ390:N40W050.N40W040.N42W030.N44W020.STG.ZMR.PDT.X/DQ", sent: sent))
        // Later: a direct from 41N 35W to 42N 30W, then 44N 20W as planned.
        let pos = AcarsRouteReport(kind: .position, time: sent.addingTimeInterval(3_600),
                                   waypoints: ["N42W030", "N44W020"].compactMap { AcarsRouteParser.token($0[...]) },
                                   position: TimedPoint(point: GeoPoint(lat: 41, lon: -35), time: sent.addingTimeInterval(3_590)))
        let route = try XCTUnwrap(AcarsRouteResolver.route(from: [pos, wind], context: AcarsRouteContext(), navDB: navDB))
        XCTAssertEqual(route.waypoints.map(\.name), ["N40W050", "N40W040", "N42W030", "N44W020", "STG", "ZMR", "PDT"])
        XCTAssertEqual(route.positions.map(\.point), [GeoPoint(lat: 41, lon: -35)])
        XCTAssertEqual(route.updated, sent.addingTimeInterval(3_600))
    }

    func testNewerFullRouteReplacesTheOlderFromWhereItJoins() throws {
        let old = try XCTUnwrap(AcarsRouteParser.report(in: "REQPWI/WQ390:N40W050.N40W040.N42W030.N44W020.STG.X/DQ", sent: sent))
        // A reroute from 40N 40W further north.
        let new = try XCTUnwrap(AcarsRouteParser.report(in: "REQPWI/WQ390:N40W040.N45W030.N47W020.X/DQ", sent: sent.addingTimeInterval(1_800)))
        let route = try XCTUnwrap(AcarsRouteResolver.route(from: [old, new], context: AcarsRouteContext(), navDB: navDB))
        XCTAssertEqual(route.waypoints.map(\.name), ["N40W050", "N40W040", "N45W030", "N47W020"])
        // One that doesn't start at a named waypoint joins where it lies along the older route.
        let mid = try XCTUnwrap(AcarsRouteParser.report(in: "REQPWI/WQ390:N41000W035000.N43W025.N44W020.X/DQ", sent: sent.addingTimeInterval(1_800)))
        let joined = try XCTUnwrap(AcarsRouteResolver.route(from: [old, mid], context: AcarsRouteContext(), navDB: navDB))
        XCTAssertEqual(joined.waypoints.map(\.name), ["N40W050", "N40W040", "N41000W035000", "N43W025", "N44W020"])
        // An unrelated route (far from the older one) replaces it.
        let far = try XCTUnwrap(AcarsRouteParser.report(in: "REQPWI/WQ390:N10W150.N12W140.X/DQ", sent: sent.addingTimeInterval(1_800)))
        let replaced = try XCTUnwrap(AcarsRouteResolver.route(from: [old, far], context: AcarsRouteContext(), navDB: navDB))
        XCTAssertEqual(replaced.waypoints.map(\.name), ["N10W150", "N12W140"])
    }

    func testPlanKeepsOnlyWaypointsAheadOfTheAircraft() throws {
        let report = try XCTUnwrap(AcarsRouteParser.report(in: transatlantic, sent: sent))
        let route = try XCTUnwrap(AcarsRouteResolver.route(from: [report], context: AcarsRouteContext(origin: jfk, destination: palma), navDB: navDB))
        // Between 40N 40W and 42N 30W.
        let aircraft = GeoPoint(lat: 41.1, lon: -35)
        let plan = try XCTUnwrap(route.plan(aircraft: aircraft, origin: jfk, destination: palma))
        XCTAssertEqual(plan.ahead.map(\.name), ["N42W030", "N44W020", "STG", "ZMR", "PDT", "PTC"])
        XCTAssertEqual(plan.remaining.first, aircraft)
        assertPoint(plan.remaining.last, palma.lat, palma.lon)
        XCTAssertEqual(plan.path.first, jfk)
        XCTAssertEqual(FlightMath.removingRepeats(plan.remaining), plan.remaining)
        // Longer than the great circle, but not absurdly.
        let direct = FlightService.gcDistance(aircraft.lat, aircraft.lon, palma.lat, palma.lon)
        XCTAssertGreaterThan(plan.remainingNM, direct)
        XCTAssertLessThan(plan.remainingNM, direct * 1.15)
        // Past the last waypoint, only the destination is ahead; off the route, there's no plan.
        let rome = GeoPoint(lat: 41.8003, lon: 12.2389)
        XCTAssertEqual(route.plan(aircraft: GeoPoint(lat: 40.4, lon: 7.5), origin: jfk, destination: rome)?.ahead, [])
        XCTAssertNil(route.plan(aircraft: GeoPoint(lat: 20, lon: -40), origin: jfk, destination: palma))
        XCTAssertNil(route.plan(aircraft: GeoPoint(lat: 39.45, lon: 3.3), origin: jfk, destination: nil))
    }

    func testPlanAcrossTheAntimeridian() throws {
        let report = try XCTUnwrap(AcarsRouteParser.report(in: "REQPWI/WQ350:N50000E160000.N50000E170000.N50000W170000.N49000W160000.X/DQ", sent: sent))
        let route = try XCTUnwrap(AcarsRouteResolver.route(from: [report], context: AcarsRouteContext(), navDB: navDB))
        let plan = try XCTUnwrap(route.plan(aircraft: GeoPoint(lat: 50.2, lon: 165), origin: nil, destination: nil))
        XCTAssertEqual(plan.ahead.map(\.name), ["N50000E170000", "N50000W170000", "N49000W160000"])
        let lines = RouteGeometry.antimeridianSafe(plan.remaining)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            for (a, b) in zip(line, line.dropFirst()) { XCTAssertLessThan(abs(a.lon - b.lon), 10) }
        }
        XCTAssertLessThan(plan.remainingNM, 1_500)
    }

    // MARK: Messages to route

    func testFlightMessagesBecomeARoute() throws {
        let json = #"""
        {"id":1,"departingAirport":"KJFK","messages":[
         {"id":3,"timestamp":"2026-11-27T05:00:00.000Z","label":"H1","text":"POSN41000W035000,N40W040,045950,380,N42W030,051500,N44W020,M50,27050,1A2B"},
         {"id":2,"timestamp":"2026-11-27T03:00:00.000Z","label":"H1","text":"- #M1BREQPWI/WQ370.380.390.400:N39539W071575.SLATN.SOORY.N40W050.N40W040.N42W030.N44W020.MUDOS.STG/DQ380"},
         {"id":1,"timestamp":"2026-11-27T02:00:00.000Z","label":"5Z","text":"REQPWI/WQ370:NOT.H1/DQ"}]}
        """#
        let f = AcarsFlight(try XCTUnwrap(AirframesAPI.decode(AirframesAPI.Flight.self, from: Data(json.utf8))), aircraftHex: "abc123")
        XCTAssertEqual(f.routeReports.map(\.kind), [.position, .windRequest])
        let route = try XCTUnwrap(AcarsRouteResolver.route(from: f.routeReports, context: AcarsRouteContext(), navDB: navDB))
        XCTAssertEqual(route.waypoints.last?.name, "STG")
        XCTAssertEqual(route.positions.count, 1)
        XCTAssertEqual(route.waypoints.count, 9)
    }

    func testBundledTableLoads() {
        let db = NavDB.bundled
        XCTAssertGreaterThan(db.count, 50_000)
        XCTAssertTrue(db.candidates(for: "STG").contains { abs($0.point.lat - 42.93) < 0.01 && $0.kind == .vhf })
        XCTAssertEqual(db.candidates(for: "SLATN").count, 1)
        XCTAssertEqual(db.candidates(for: "ZZZZZ"), [])
    }
}
