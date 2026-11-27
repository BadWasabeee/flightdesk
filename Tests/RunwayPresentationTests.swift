import XCTest

/// Runway phases as the surfaces show them: trails with altitude and ground flags, compact tags,
/// list smoothing, the map highlight and the shared position wording.
final class RunwayPresentationTests: XCTestCase {
    private let ord = Airport(code: "ORD", city: "Chicago", lat: 41.98, lon: -87.90)
    private let mke = Airport(code: "MKE", city: "Milwaukee", lat: 42.95, lon: -87.90)
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private let end28C = RunwayEnd(ident: "28C", threshold: GeoPoint(lat: 41.965698, lon: -87.891800), heading: 270)
    private let end10C = RunwayEnd(ident: "10C", threshold: GeoPoint(lat: 41.965698, lon: -87.931503), heading: 90)
    private var analyzer: ApproachAnalyzer {
        ApproachAnalyzer(airports: [AirportRunways(airport: ord, runways: [Runway(low: end10C, high: end28C, lengthFt: 10_800, elevationFt: 669)])])
    }

    private func flight(at p: GeoPoint, track: Double, alt: Int, vr: Double = 0, gs: Double = 150) -> Flight {
        let json = """
        {"hex":"abc123","flight":"UAL1189","t":"B39M","alt_baro":\(alt),"gs":\(gs),"track":\(track),
         "lat":\(p.lat),"lon":\(p.lon),"dst":10,"dir":90,"baro_rate":\(vr)}
        """
        return Flight(adsb: try! JSONDecoder().decode(ADSBAircraft.self, from: Data(json.utf8)))!
    }

    private func move(_ p: GeoPoint, _ bearing: Double, _ nm: Double) -> GeoPoint {
        RouteGeometry.destination(from: p, bearing: bearing, distanceNM: nm)
    }

    private func final(_ nm: Double, airport: Airport? = nil, runway: String = "28C") -> RunwayPhase {
        .finalApproach(FinalApproach(airport: airport ?? ord, runway: runway, distanceNM: nm, crossTrackNM: 0,
                                     glidepathDeviationFt: 0, glidepath: .onPath, eta: nm / 150 * 3_600))
    }

    private var standard: DisplayOptions { var o = DisplayOptions(); o.style = .standard; return o }
    private var led: DisplayOptions { DisplayOptions() }

    // MARK: Trail with altitude and ground flag

    func testTrackKeepsPerPointAltitudeAndGroundFlag() throws {
        let end = t0.timeIntervalSince1970 - 60
        let track = try XCTUnwrap(FlightTrack(waypoints: [[end - 900, 41.97, -87.93, NSNull(), 90, true],
                                                          [end - 600, 41.97, -87.80, 610.0, 90, false],
                                                          [end, 42.5, -87.0, 3048.0, 45, false]],
                                              current: nil, now: t0))
        XCTAssertNil(track.points[0].altitudeFt)
        XCTAssertTrue(track.points[0].onGround)
        XCTAssertEqual(try XCTUnwrap(track.points[1].altitudeFt), 2_001, accuracy: 1)
        XCTAssertFalse(track.points[1].onGround)
        XCTAssertEqual(try XCTUnwrap(track.points[2].altitudeFt), 10_000, accuracy: 1)
        XCTAssertNil(track.startAltitudeFt, "the first point's altitude, which OpenSky left out")
    }

    func testGroundSamplesOnTheCentrelineAreATakeoffNotAGoAround() {
        func trail(onGround: Bool) -> [TimedPoint] {
            [(1.5, t0), (1.0, t0 + 30)].map { nm, t in
                TimedPoint(point: move(end28C.threshold, 90, nm), time: t, altitudeFt: onGround ? nil : 1_100, onGround: onGround)
            }
        }
        let climbing = flight(at: move(end28C.threshold, 270, 0.5), track: 270, alt: 1_600, vr: 1_500, gs: 140)
        XCTAssertEqual(analyzer.phase(of: climbing, trail: trail(onGround: false)), .goAround(airport: ord, runway: "28C"))
        XCTAssertEqual(analyzer.phase(of: climbing, trail: trail(onGround: true)), .takingOff(airport: ord, runway: "28C"))
    }

    // MARK: Compact tags

    func testTagsInBothStylesAndUnits() {
        XCTAssertEqual(final(6.04).tag(standard), "Final 28C · 6 nm")
        XCTAssertEqual(final(6.04).tag(led), "Final 28C · 6NM")
        XCTAssertEqual(final(1.44).tag(standard), "Final 28C · 1.4 nm")
        XCTAssertEqual(final(6.04).tag(standard, distance: false), "Final 28C")
        var metric = standard
        metric.units = .metric
        XCTAssertEqual(final(6.04).tag(metric), "Final 28C · 11 km")
        XCTAssertEqual(RunwayPhase.landed(airport: ord, runway: "28C").tag(standard), "Landed 28C")
        XCTAssertEqual(RunwayPhase.takingOff(airport: ord, runway: "10L").tag(standard), "Departing 10L")
        XCTAssertEqual(RunwayPhase.taxiing(airport: ord).tag(standard), "Taxiing")
        XCTAssertEqual(RunwayPhase.goAround(airport: ord, runway: "28C").tag(standard), "Go-around 28C")
        XCTAssertTrue(RunwayPhase.goAround(airport: ord, runway: "28C").isCaution)
        XCTAssertNil(RunwayPhase.departed(airport: ord, runway: "10L", time: t0).tag(standard))
    }

    func testListRowSubtitleLeadsWithThePhase() throws {
        var f = flight(at: move(end28C.threshold, 90, 6), track: 270, alt: 2_600, vr: -800)
        XCTAssertNil(FlightRowText.phaseSubtitle(f, phase: nil, options: led))
        let typeOnly = try XCTUnwrap(FlightRowText.phaseSubtitle(f, phase: final(6), options: led))
        XCTAssertEqual(typeOnly.tag, "Final 28C · 6 nm", "list text is never in the LED style")
        XCTAssertEqual(typeOnly.rest, "B39M")
        f.route = RouteInfo(airline: "United Airlines", flightNo: "UA1189", airlineCode: "UA", from: mke, to: ord)
        XCTAssertEqual(FlightRowText.phaseSubtitle(f, phase: final(6), options: standard)?.rest, "MKE → ORD")
    }

    // MARK: List smoothing

    func testShortFinalThenOverTheRunwayReadsAsLanded() {
        let over = flight(at: move(end28C.threshold, 270, 0.5), track: 270, alt: 700, vr: -300, gs: 135)
        let landed = RunwayPhase.landed(airport: ord, runway: "28C")
        XCTAssertEqual(RunwayPhase.listed(nil, previous: final(1.2), flight: over), landed)
        XCTAssertEqual(RunwayPhase.listed(nil, previous: landed, flight: over), landed, "stays until the aircraft leaves the feed")
        XCTAssertNil(RunwayPhase.listed(nil, previous: final(6), flight: over), "still far out: nothing to hold on to")
        let climbing = flight(at: move(end28C.threshold, 270, 0.5), track: 270, alt: 1_200, vr: 1_500, gs: 140)
        XCTAssertNil(RunwayPhase.listed(nil, previous: final(1.2), flight: climbing), "climbing away is not a landing")
        XCTAssertEqual(RunwayPhase.listed(final(0.8), previous: final(1.2), flight: over), final(0.8))
    }

    func testListPhasesSkipHighFlightsAndUseTheBundledRunways() throws {
        XCTAssertNil(ApproachAnalyzer.listPhase(of: flight(at: ord.geoPoint, track: 270, alt: 15_000, vr: -1_000)))
        let threshold = try XCTUnwrap(RunwayDB.runwayEnd("28C", code: "ORD")).end
        let onFinal = flight(at: move(threshold.threshold, threshold.heading + 180, 6), track: threshold.heading,
                             alt: 669 + 1_960, vr: -800)
        let phases = RunwayPhase.listPhases(for: [onFinal], previous: [:], phase: ApproachAnalyzer.listPhase)
        guard case .finalApproach(let fa)? = phases[onFinal.id] else { return XCTFail("expected final, got \(phases)") }
        XCTAssertEqual(fa.runway, "28C")
        XCTAssertEqual(fa.distanceNM, 6, accuracy: 0.1)
    }

    // MARK: Map highlight

    func testHighlightDrawsTheRunwayAndOnFinalTheCentreline() throws {
        let lookup: (String, String) -> (end: RunwayEnd, far: RunwayEnd)? = { ident, code in
            code == "ORD" && ident == "28C" ? (self.end28C, self.end10C) : nil
        }
        let onFinal = RunwayHighlight(phase: final(6), lookup: lookup)
        XCTAssertEqual(onFinal.runway, [end28C.threshold, end10C.threshold])
        XCTAssertEqual(onFinal.centreline.count, 2)
        let out = try XCTUnwrap(onFinal.centreline.first)
        XCTAssertEqual(FlightService.gcDistance(out.lat, out.lon, end28C.threshold.lat, end28C.threshold.lon), 10, accuracy: 0.01)
        XCTAssertGreaterThan(out.lon, end28C.threshold.lon, "landing west, the approach is to the east")
        XCTAssertEqual(onFinal.centreline.last, end28C.threshold)

        let landed = RunwayHighlight(phase: .landed(airport: ord, runway: "28C"), lookup: lookup)
        XCTAssertEqual(landed.runway.count, 2)
        XCTAssertTrue(landed.centreline.isEmpty)
        XCTAssertTrue(RunwayHighlight(phase: .departed(airport: ord, runway: "28C", time: t0), lookup: lookup).isEmpty)
        XCTAssertTrue(RunwayHighlight(phase: final(6, runway: "27L"), lookup: lookup).isEmpty)
    }

    // MARK: Wording

    func testTouchdownLine() {
        guard case .finalApproach(let fa) = final(6) else { return XCTFail() }
        let line = PositionDescriber.touchdown(fa, now: t0, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(line.hasPrefix("Touchdown ≈ 8:02"), line)
        XCTAssertTrue(line.hasSuffix("(in 2 m)"), line)
    }

    func testLocationRelativeToAnAirportIsSharedWithACARS() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(PositionDescriber.location(of: move(ord.geoPoint, 315, 12), airport: ord, locale: en), "12 nm NW of ORD")
        XCTAssertEqual(PositionDescriber.location(of: move(ord.geoPoint, 0, 1), airport: ord, locale: en), "Over ORD")
        XCTAssertEqual(PositionDescriber.location(of: move(ord.geoPoint, 0, 1), airport: ord, grounded: true, locale: en), "At ORD")
        XCTAssertNil(PositionDescriber.location(of: move(ord.geoPoint, 0, 50), airport: ord, locale: en))
        let acars = AcarsContentDecoder.describe(GeoPoint(lat: 41.98, lon: -87.90))
        XCTAssertTrue(acars.hasSuffix("(Over ORD)"), acars)
    }

    #if DEBUG
    func testSnapshotSampleFeaturesAFlightOnFinal() {
        let m = PanelModel.approach
        guard let id = m.featured?.id, case .finalApproach(let fa)? = m.runwayPhases[id] else {
            return XCTFail("expected the featured sample flight on final, got \(m.runwayPhases)")
        }
        XCTAssertEqual(fa.airport.code, "DEN")
        XCTAssertEqual(fa.runway, "16R")
        XCTAssertEqual(fa.distanceNM, 6, accuracy: 0.2)
    }
    #endif
}
