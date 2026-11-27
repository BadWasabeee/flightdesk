import XCTest

/// Runway phase detection and plain-language position, on fixture runways (not the bundled table).
final class ApproachTests: XCTestCase {

    // MARK: Fixtures (OurAirports coordinates)

    private let ord = Airport(code: "ORD", city: "Chicago", lat: 41.98, lon: -87.90)
    private let mke = Airport(code: "MKE", city: "Milwaukee", lat: 42.95, lon: -87.90)
    private let den = Airport(code: "DEN", city: "Denver", lat: 39.86, lon: -104.67)
    private let test = Airport(code: "TST", city: "Test", lat: 45.0, lon: -100.0)

    private let rwy10C28C = Runway(low: RunwayEnd(ident: "10C", threshold: GeoPoint(lat: 41.965698, lon: -87.931503), heading: 90),
                                   high: RunwayEnd(ident: "28C", threshold: GeoPoint(lat: 41.965698, lon: -87.891800), heading: 270),
                                   lengthFt: 10_800, elevationFt: 669)
    private let rwy10L28R = Runway(low: RunwayEnd(ident: "10L", threshold: GeoPoint(lat: 41.969002, lon: -87.931503), heading: 90),
                                   high: RunwayEnd(ident: "28R", threshold: GeoPoint(lat: 41.969101, lon: -87.883698), heading: 270),
                                   lengthFt: 13_000, elevationFt: 672)
    private let rwy01L19R = Runway(low: RunwayEnd(ident: "01L", threshold: GeoPoint(lat: 42.930499, lon: -87.897643), heading: 7),
                                   high: RunwayEnd(ident: "19R", threshold: GeoPoint(lat: 42.957699, lon: -87.892998), heading: 187),
                                   lengthFt: 9_990, elevationFt: 704)
    /// A north–south runway whose 36 end points at 358° true, for wraparound.
    private var rwy18_36: Runway {
        let south = GeoPoint(lat: 45.0, lon: -100.0)
        return Runway(low: RunwayEnd(ident: "18", threshold: move(south, 358, 1.5), heading: 178),
                      high: RunwayEnd(ident: "36", threshold: south, heading: 358), lengthFt: 9_000, elevationFt: 1_500)
    }

    private var airports: [AirportRunways] {
        [AirportRunways(airport: ord, runways: [rwy10C28C, rwy10L28R]),
         AirportRunways(airport: mke, runways: [rwy01L19R]),
         AirportRunways(airport: test, runways: [rwy18_36])]
    }

    private func analyzer(origin: Airport? = nil, destination: Airport? = nil) -> ApproachAnalyzer {
        ApproachAnalyzer(airports: airports, origin: origin, destination: destination)
    }

    private func flight(at p: GeoPoint, track: Double, alt: Int, vr: Double = 0, gs: Double = 150) -> Flight {
        let json = """
        {"hex":"abc123","flight":"UAL1189","t":"B39M","alt_baro":\(alt),"gs":\(gs),"track":\(track),
         "lat":\(p.lat),"lon":\(p.lon),"dst":10,"dir":90,"baro_rate":\(vr)}
        """
        return Flight(adsb: try! JSONDecoder().decode(ADSBAircraft.self, from: Data(json.utf8)))!
    }

    /// The point `nm` from `p` along `bearing` (great circle).
    private func move(_ p: GeoPoint, _ bearing: Double, _ nm: Double) -> GeoPoint {
        let δ = nm / 3440.065, θ = bearing * .pi / 180, φ1 = p.lat * .pi / 180, λ1 = p.lon * .pi / 180
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return GeoPoint(lat: φ2 * 180 / .pi, lon: λ2 * 180 / .pi)
    }

    private var threshold28C: GeoPoint { rwy10C28C.high.threshold }
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func final(_ phase: RunwayPhase?, file: StaticString = #filePath, line: UInt = #line) -> FinalApproach? {
        guard case .finalApproach(let f)? = phase else {
            XCTFail("expected final approach, got \(String(describing: phase))", file: file, line: line)
            return nil
        }
        return f
    }

    // MARK: Final approach

    func testAlignedFinalAtSixMilesOn28C() throws {
        let f = flight(at: move(threshold28C, 90, 6), track: 270, alt: 669 + 50 + 1_910, vr: -800, gs: 150)
        let fa = try XCTUnwrap(final(analyzer(destination: ord).phase(of: f)))
        XCTAssertEqual(fa.airport, ord)
        XCTAssertEqual(fa.runway, "28C")
        XCTAssertEqual(fa.distanceNM, 6, accuracy: 0.05)
        XCTAssertEqual(fa.crossTrackNM, 0, accuracy: 0.02)
        XCTAssertEqual(fa.eta, 144, accuracy: 2)
        XCTAssertEqual(fa.glidepath, .onPath)
        XCTAssertEqual(try XCTUnwrap(fa.glidepathDeviationFt), 0, accuracy: 20)
    }

    func testGlidepathHighAndLow() {
        let p = move(threshold28C, 90, 6)
        XCTAssertEqual(final(analyzer().phase(of: flight(at: p, track: 270, alt: 3_400, vr: -1_200)))?.glidepath, .high)
        XCTAssertEqual(final(analyzer().phase(of: flight(at: p, track: 270, alt: 1_900, vr: -400)))?.glidepath, .low)
    }

    func testParallelRunwaysPickTheNearestCentreline() {
        // On 28R's centreline: 28C is 0.2 nm to the side.
        let onR = flight(at: move(rwy10L28R.high.threshold, 90, 6), track: 270, alt: 2_600, vr: -700)
        XCTAssertEqual(final(analyzer().phase(of: onR))?.runway, "28R")
        // Between the two but nearer 28C.
        let nearC = flight(at: move(move(threshold28C, 90, 6), 0, 0.06), track: 271, alt: 2_600, vr: -700)
        let fa = final(analyzer().phase(of: nearC))
        XCTAssertEqual(fa?.runway, "28C")
        XCTAssertEqual(fa?.crossTrackNM ?? 0, 0.06, accuracy: 0.02)   // north of centreline = right, landing west
    }

    func testInterceptingOrOffsetIsNotFinal() {
        // On the centreline but cutting across it at 30°.
        XCTAssertNil(analyzer().phase(of: flight(at: move(threshold28C, 90, 8), track: 300, alt: 3_000, vr: -700)))
        // Aligned but 2 nm south of the centreline.
        XCTAssertNil(analyzer().phase(of: flight(at: move(move(threshold28C, 90, 8), 180, 2), track: 270, alt: 3_000, vr: -700)))
        // Past the threshold, over the runway (not on final, not on the ground).
        XCTAssertNil(analyzer().phase(of: flight(at: move(threshold28C, 270, 3), track: 270, alt: 900, vr: -700)))
    }

    func testTooHighOrClimbingIsNotFinal() {
        let p = move(threshold28C, 90, 6)
        XCTAssertNil(analyzer().phase(of: flight(at: p, track: 270, alt: 9_000, vr: -1_500)))
        XCTAssertNil(analyzer().phase(of: flight(at: p, track: 270, alt: 2_600, vr: 1_500)))
        // Level is fine low down, not at 5,500 ft AGL.
        XCTAssertNotNil(final(analyzer().phase(of: flight(at: p, track: 270, alt: 2_600, vr: 0))))
        XCTAssertNil(analyzer().phase(of: flight(at: move(threshold28C, 90, 18), track: 270, alt: 6_200, vr: 0)))
    }

    func testHeadingWraparound() {
        // Runway 36 points at 358°; a track of 004° is 6° off.
        let f = flight(at: move(rwy18_36.high.threshold, 178, 5), track: 4, alt: 1_500 + 1_650, vr: -700)
        XCTAssertEqual(final(analyzer().phase(of: f))?.runway, "36")
        // MKE 01L points at 007°: 355° is aligned, 340° is not.
        let mkeFinal = move(rwy01L19R.low.threshold, 187, 5)
        XCTAssertEqual(final(analyzer().phase(of: flight(at: mkeFinal, track: 355, alt: 2_400, vr: -700)))?.runway, "01L")
        XCTAssertNil(analyzer().phase(of: flight(at: mkeFinal, track: 340, alt: 2_400, vr: -700)))
    }

    func testKnownDestinationIsPreferred() {
        // A second airport's runway 36 parallels TST's 0.5 nm to the east.
        let other = Airport(code: "OTH", city: "Other", lat: 45.0, lon: -99.99)
        let east = { (p: GeoPoint) in self.move(p, 88, 0.5) }
        let parallel = Runway(low: RunwayEnd(ident: "18", threshold: east(rwy18_36.low.threshold), heading: 178),
                              high: RunwayEnd(ident: "36", threshold: east(rwy18_36.high.threshold), heading: 358),
                              lengthFt: 9_000, elevationFt: 1_500)
        let both = airports + [AirportRunways(airport: other, runways: [parallel])]
        // 0.1 nm east of TST's centreline, 0.4 nm west of the other's.
        let f = flight(at: move(move(rwy18_36.high.threshold, 178, 5), 88, 0.1), track: 358, alt: 3_150, vr: -700)
        XCTAssertEqual(final(ApproachAnalyzer(airports: both).phase(of: f))?.airport, test)
        XCTAssertEqual(final(ApproachAnalyzer(airports: both, destination: other).phase(of: f))?.airport, other)
    }

    func testQNHCorrectsPressureAltitude() {
        // 2,630 ft pressure altitude on a 1,033 hPa day is about 3,170 ft: above the glidepath.
        let f = flight(at: move(threshold28C, 90, 6), track: 270, alt: 2_630, vr: -800)
        XCTAssertEqual(final(analyzer().phase(of: f, qnhHPa: 1_033))?.glidepath, .high)
    }

    // MARK: Ground

    func testLandedRollout() {
        let p = move(threshold28C, 270, 0.6)
        let f = flight(at: p, track: 270, alt: 650, gs: 110)
        XCTAssertEqual(analyzer(origin: den, destination: ord).phase(of: f, onGround: true), .landed(airport: ord, runway: "28C"))
        // Without a route, a trail from far away shows it arrived.
        let trail = [TimedPoint(point: move(threshold28C, 90, 30), time: t0, altitudeFt: 9_000),
                     TimedPoint(point: move(threshold28C, 90, 5), time: t0 + 600, altitudeFt: nil)]
        XCTAssertEqual(analyzer().phase(of: f, onGround: true, trail: trail), .landed(airport: ord, runway: "28C"))
        // Low and slow counts as on the ground even without the flag.
        XCTAssertEqual(analyzer(destination: ord).phase(of: flight(at: p, track: 270, alt: 700, gs: 60)), .landed(airport: ord, runway: "28C"))
        // Nothing to tell landing from takeoff.
        XCTAssertEqual(analyzer().phase(of: f, onGround: true), .onRunway(airport: ord, runway: "28C"))
    }

    func testTakeoffRollFromOrigin() {
        let f = flight(at: move(rwy10L28R.low.threshold, 90, 0.4), track: 90, alt: 650, gs: 90)
        XCTAssertEqual(analyzer(origin: ord, destination: den).phase(of: f, onGround: true), .takingOff(airport: ord, runway: "10L"))
    }

    func testTaxiing() {
        let f = flight(at: GeoPoint(lat: 41.978, lon: -87.905), track: 180, alt: 650, gs: 15)
        XCTAssertEqual(analyzer().phase(of: f, onGround: true), .taxiing(airport: ord))
        // Slowly crossing a runway is taxiing too.
        let crossing = flight(at: move(threshold28C, 270, 1), track: 0, alt: 650, gs: 10)
        XCTAssertEqual(analyzer().phase(of: crossing, onGround: true), .taxiing(airport: ord))
        // On the ground far from any runway: nothing.
        XCTAssertNil(analyzer().phase(of: flight(at: GeoPoint(lat: 41.5, lon: -88.5), track: 0, alt: 650, gs: 10), onGround: true))
    }

    // MARK: Takeoff and departure

    func testClimbingOutAligned() {
        let f = flight(at: move(rwy10L28R.high.threshold, 90, 1), track: 90, alt: 1_500, vr: 2_500, gs: 170)
        XCTAssertEqual(analyzer(origin: ord, destination: den).phase(of: f), .takingOff(airport: ord, runway: "10L"))
        // Climbing over the destination's runway without a trail could be a go-around: say nothing.
        XCTAssertNil(analyzer(origin: den, destination: ord).phase(of: f))
    }

    func testDepartedFromTrail() {
        let start = rwy10L28R.low.threshold
        let trail = [TimedPoint(point: move(start, 90, 0.1), time: t0, altitudeFt: 670),
                     TimedPoint(point: move(start, 90, 0.8), time: t0 + 20, altitudeFt: nil),
                     TimedPoint(point: move(start, 90, 2.0), time: t0 + 40, altitudeFt: nil),
                     TimedPoint(point: move(start, 92, 5.5), time: t0 + 90, altitudeFt: nil),
                     TimedPoint(point: move(start, 110, 20), time: t0 + 300, altitudeFt: nil)]
        let cruising = flight(at: move(start, 240, 300), track: 240, alt: 37_000, gs: 460)
        XCTAssertEqual(analyzer(origin: ord).phase(of: cruising, trail: trail), .departed(airport: ord, runway: "10L", time: t0))
        XCTAssertEqual(analyzer(origin: ord).departure(trail: trail), .departed(airport: ord, runway: "10L", time: t0))
        // A trail that starts in the air far away says nothing about the departure.
        XCTAssertNil(analyzer().departure(trail: Array(trail.dropFirst(4)) + [TimedPoint(point: move(start, 110, 40), time: t0 + 400)]))
    }

    func testTaxiOnAParallelTaxiwayIsNotATakeoff() {
        // 0.1 nm north of 10L, moving east, then turning off.
        let start = move(rwy10L28R.low.threshold, 0, 0.1)
        let trail = [TimedPoint(point: start, time: t0), TimedPoint(point: move(start, 90, 0.5), time: t0 + 120),
                     TimedPoint(point: move(move(start, 90, 0.5), 0, 0.5), time: t0 + 240)]
        XCTAssertNil(analyzer(origin: ord).departure(trail: trail))
    }

    // MARK: Go-around

    func testGoAround() {
        let trail = [TimedPoint(point: move(threshold28C, 90, 5), time: t0, altitudeFt: 2_300),
                     TimedPoint(point: move(threshold28C, 90, 3), time: t0 + 50, altitudeFt: 1_650),
                     TimedPoint(point: move(threshold28C, 90, 1.5), time: t0 + 90, altitudeFt: 1_150)]
        let f = flight(at: move(threshold28C, 270, 0.5), track: 270, alt: 1_600, vr: 1_500, gs: 140)
        XCTAssertEqual(analyzer(destination: ord).phase(of: f, trail: trail), .goAround(airport: ord, runway: "28C"))
        // The same climb without a trail is not called a go-around.
        XCTAssertNil(analyzer(destination: ord).phase(of: f))
    }

    // MARK: Runway table

    func testParsesRunwayCSV() {
        let text = """
        # header
        KORD,10C,41.965698,-87.931503,90.0,28C,41.965698,-87.891800,270.0,10800,669
        KORD,10L,41.969002,-87.931503,90.0,28R,41.969101,-87.883698,270.0,,672
        KBAD,09,x,-87.9,90.0,27,41.9,-87.8,270.0,5000,600
        KMKE,01L,42.930499,-87.897643,7.0,19R,42.957699,-87.892998,187.0,9990,704
        """
        let table = RunwayDB.parse(text)
        XCTAssertEqual(table.keys.sorted(), ["KMKE", "KORD"])
        XCTAssertEqual(table["KORD"]?.first, rwy10C28C)
        XCTAssertEqual(table["KORD"]?.last?.name, "10L/28R")
        XCTAssertNil(table["KORD"]?.last?.lengthFt)
    }

    // MARK: Describer

    private let en = Locale(identifier: "en_US")
    private var imperial: DisplayOptions { DisplayOptions() }      // LED style: sentences still read "6,000 ft"
    private var metric: DisplayOptions { var o = DisplayOptions(); o.units = .metric; return o }

    func testDescribesFinalApproach() {
        let f = flight(at: move(threshold28C, 90, 6), track: 270, alt: 2_630, vr: -800)
        let phase = analyzer(destination: ord).phase(of: f)
        let d = PositionDescriber.describe(f, phase: phase, nearest: ord, options: imperial, locale: en)
        XCTAssertEqual(d.phase, "Final RWY 28C at ORD · 6.0 nm · on glidepath")
        XCTAssertEqual(d.vertical, "Descending through 2,600 ft")
        XCTAssertEqual(d.headline, d.phase)
        let m = PositionDescriber.describe(f, phase: phase, nearest: ord, options: metric, locale: en)
        XCTAssertEqual(m.phase, "Final RWY 28C at ORD · 11 km · on glidepath")
        XCTAssertEqual(m.vertical, "Descending through 792 m")
    }

    func testDescribesCruiseAndLocation() {
        let f = flight(at: move(ord.geoPoint, 315, 12), track: 90, alt: 37_020, gs: 450)
        let d = PositionDescriber.describe(f, phase: nil, nearest: ord, nextFix: NextFix(name: "PAITN", distanceNM: 34),
                                           options: imperial, locale: en)
        XCTAssertEqual(d.vertical, "Cruising at FL370")
        XCTAssertEqual(d.location, "12 nm NW of ORD")
        XCTAssertEqual(d.next, "Next waypoint PAITN · 34 nm")
        XCTAssertEqual(d.headline, "Cruising at FL370")
        XCTAssertEqual(d.lines, ["Cruising at FL370", "12 nm NW of ORD", "Next waypoint PAITN · 34 nm"])
        let m = PositionDescriber.describe(f, phase: nil, nearest: ord, options: metric, locale: en)
        XCTAssertEqual(m.vertical, "Cruising at 11,277 m (FL370)")
        XCTAssertEqual(m.location, "22 km NW of ORD")
    }

    func testDescribesVerticalStates() {
        let p = GeoPoint(lat: 41.5, lon: -88.5)
        func vertical(_ alt: Int, _ vr: Double) -> String? {
            PositionDescriber.describe(flight(at: p, track: 0, alt: alt, vr: vr), phase: nil, nearest: nil, options: imperial, locale: en).vertical
        }
        XCTAssertEqual(vertical(6_040, -1_200), "Descending through 6,000 ft")
        XCTAssertEqual(vertical(24_000, 1_800), "Climbing through FL240")
        XCTAssertEqual(vertical(4_000, 0), "Level at 4,000 ft")
    }

    func testDescribesRunwayPhases() {
        let ground = flight(at: move(threshold28C, 270, 0.6), track: 270, alt: 650, gs: 110)
        let landed = PositionDescriber.describe(ground, phase: .landed(airport: ord, runway: "28C"), nearest: ord,
                                                onGround: true, options: imperial, locale: en)
        XCTAssertEqual(landed.phase, "Landed at ORD on RWY 28C")
        XCTAssertNil(landed.vertical)
        XCTAssertEqual(landed.location, "At ORD")

        let climb = flight(at: move(rwy10L28R.high.threshold, 90, 1), track: 90, alt: 1_500, vr: 2_500, gs: 170)
        XCTAssertEqual(PositionDescriber.describe(climb, phase: .takingOff(airport: ord, runway: "10L"), nearest: ord,
                                                  options: imperial, locale: en).phase, "Climbing out of ORD on RWY 10L")
        XCTAssertEqual(PositionDescriber.describe(ground, phase: .takingOff(airport: ord, runway: "10L"), nearest: ord,
                                                  onGround: true, options: imperial, locale: en).phase, "Taking off from ORD on RWY 10L")

        // A departure is history: the headline stays on what the aircraft is doing now.
        let cruise = flight(at: move(ord.geoPoint, 240, 300), track: 240, alt: 37_000, gs: 460)
        let departed = PositionDescriber.describe(cruise, phase: .departed(airport: ord, runway: "10L", time: t0), nearest: nil,
                                                  options: imperial, locale: en, now: t0 + 3_000)
        XCTAssertEqual(departed.phase, "Departed ORD on RWY 10L · 50 m ago")
        XCTAssertEqual(departed.headline, "Cruising at FL370")
    }
}
