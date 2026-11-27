import XCTest

final class IntentsTests: XCTestCase {

    private let us = Locale(identifier: "en_US")
    private let ord = Airport(code: "ORD", city: "Chicago", lat: 41.98, lon: -87.90)
    private let den = Airport(code: "DEN", city: "Denver", lat: 39.86, lon: -104.67)

    private func flight(hex: String = "a1b2c3", callsign: String = "UAL1543", reg: String = "N37522", type: String = "B738",
                        alt: Int = 7_310, rate: Double = -1_200, dist: Double = 4.2, dir: Double = 2,
                        squawk: String? = nil) -> Flight {
        let sq = squawk.map { ",\"squawk\":\"\($0)\"" } ?? ""
        let json = """
        {"hex":"\(hex)","flight":"\(callsign)","r":"\(reg)","t":"\(type)","alt_baro":\(alt),"gs":250,"track":270,
         "lat":39.8,"lon":-104.9,"dst":\(dist),"dir":\(dir),"baro_rate":\(rate)\(sq)}
        """
        return Flight(adsb: try! JSONDecoder().decode(ADSBAircraft.self, from: Data(json.utf8)))!
    }

    private func united() -> Flight {
        var f = flight()
        f.route = RouteInfo(airline: "United Airlines", flightNo: "UA1543", airlineCode: "UA", from: ord, to: den)
        f.aircraft = AircraftInfo(model: "Boeing 737-800", owner: "United Airlines")
        return f
    }

    // MARK: Summary text

    func testAirlineSummaryImperial() {
        XCTAssertEqual(FlightSpeech.summary(of: united(), units: .imperial, locale: us),
                       "United 1543, a Boeing 737 from Chicago to Denver, 4 nautical miles north at 7,300 feet, descending.")
    }

    func testAirlineSummaryMetric() {
        XCTAssertEqual(FlightSpeech.summary(of: united(), units: .metric, locale: us),
                       "United 1543, a Boeing 737 from Chicago to Denver, 8 kilometers north at 2,230 meters, descending.")
    }

    func testClimbingAndLevel() {
        var f = flight(rate: 1_500)
        XCTAssertTrue(FlightSpeech.summary(of: f, units: .imperial, locale: us).hasSuffix(", climbing."))
        f = flight(rate: 100)
        let level = FlightSpeech.summary(of: f, units: .imperial, locale: us)
        XCTAssertFalse(level.contains("climbing") || level.contains("descending"))
        XCTAssertTrue(level.hasSuffix("at 7,300 feet."))
    }

    func testMissingRouteFallsBackToCallsignAndTypeCode() {
        let text = FlightSpeech.summary(of: flight(), units: .imperial, locale: us)
        XCTAssertEqual(text, "UAL1543, a B738, 4 nautical miles north at 7,300 feet, descending.")
        XCTAssertFalse(text.contains("from"))
    }

    func testGeneralAviationUsesRegistrationAndModel() {
        var f = flight(callsign: "", reg: "N172SP", type: "C172", alt: 2_480, rate: 0, dist: 1.0, dir: 90)
        f.aircraft = AircraftInfo(model: "Cessna 172S Skyhawk", owner: "Jane Doe")
        XCTAssertEqual(FlightSpeech.summary(of: f, units: .imperial, locale: us),
                       "N172SP, a Cessna 172S Skyhawk, 1 nautical mile east at 2,500 feet.")
    }

    func testHelicopterWording() {
        var f = flight(callsign: "N911FL", reg: "N911FL", type: "EC35", alt: 950, rate: 0, dist: 0.3)
        XCTAssertEqual(FlightSpeech.aircraftPhrase(of: f), "an EC35 helicopter")
        f.aircraft = AircraftInfo(model: "Airbus H135", owner: nil)
        XCTAssertEqual(FlightSpeech.summary(of: f, units: .imperial, locale: us),
                       "N911FL, an Airbus H135 helicopter, directly overhead at 950 feet.")
    }

    func testSituationIsSpoken() {
        let text = FlightSpeech.summary(of: flight(squawk: "7700"), units: .imperial, locale: us)
        XCTAssertTrue(text.hasSuffix(" Emergency, squawking 7700."))
    }

    func testOverheadListsOthersAndEmptyState() {
        let near = united()
        let far = flight(hex: "b2c3d4", callsign: "DAL12", dist: 9)
        let text = FlightSpeech.overhead([far, near], radiusNM: 25, units: .imperial, locale: us)
        XCTAssertTrue(text.hasPrefix("United 1543"))
        XCTAssertTrue(text.hasSuffix(" Also nearby: DAL12."))
        XCTAssertEqual(FlightSpeech.overhead([], radiusNM: 25, units: .metric),
                       "Nothing is flying within 46 kilometers right now.")
    }

    func testWordingHelpers() {
        XCTAssertEqual(FlightSpeech.spokenAirline("Delta Air Lines"), "Delta")
        XCTAssertEqual(FlightSpeech.spokenAirline("British Airways"), "British Airways")
        XCTAssertEqual(FlightSpeech.simplifiedModel("Airbus A321-211"), "Airbus A321")
        XCTAssertEqual(FlightSpeech.simplifiedModel("Boeing 787-9"), "Boeing 787-9")
        XCTAssertEqual(FlightSpeech.simplifiedModel("Boeing 737 MAX 8"), "Boeing 737 MAX 8")
        XCTAssertEqual(FlightSpeech.article(for: "Airbus A320"), "an")
        XCTAssertEqual(FlightSpeech.article(for: "F16"), "an")
        XCTAssertEqual(FlightSpeech.article(for: "B738"), "a")
        XCTAssertEqual(FlightSpeech.list(["A", "B", "C"]), "A, B and C")
        XCTAssertEqual(FlightSpeech.nearbyCount(1, radiusNM: 10, units: .imperial), "1 flight within 10 nautical miles.")
    }

    // MARK: Find Flight matching

    func testMatchingIsCaseInsensitiveAcrossIdentifiers() {
        let f = united()
        XCTAssertTrue(FlightMatcher.matches("ual1543", f))
        XCTAssertTrue(FlightMatcher.matches(" UAL 1543 ", f))
        XCTAssertTrue(FlightMatcher.matches("ua1543", f))
        XCTAssertTrue(FlightMatcher.matches("n37522", f))
        XCTAssertTrue(FlightMatcher.matches("A1B2C3", f))
        XCTAssertFalse(FlightMatcher.matches("UAL154", f))
        XCTAssertFalse(FlightMatcher.matches("", f))
    }

    func testRegistrationIgnoresDashes() {
        let f = flight(callsign: "EZY12AB", reg: "G-EZUA")
        XCTAssertTrue(FlightMatcher.matches("gezua", f))
        XCTAssertTrue(FlightMatcher.matches("g-ezua", f))
    }

    func testFindPicksNearestMatchAndSearchIsPrefix() {
        let a = flight(hex: "aaaaaa", callsign: "SWA1", dist: 12)
        let b = flight(hex: "bbbbbb", callsign: "SWA1", dist: 3)
        let c = flight(hex: "cccccc", callsign: "SWA22", dist: 1)
        XCTAssertEqual(FlightMatcher.find("swa1", in: [a, b, c])?.id, "bbbbbb")
        XCTAssertNil(FlightMatcher.find("DAL1", in: [a, b, c]))
        XCTAssertEqual(FlightMatcher.search("swa", in: [a, b, c]).map(\.id), ["cccccc", "bbbbbb", "aaaaaa"])
    }

    // MARK: Data

    func testFetchRadiusReusesCachedAreas() {
        XCTAssertEqual(IntentFlights.fetchRadius(requestedNM: nil, appRadiusNM: 25), 25)
        XCTAssertEqual(IntentFlights.fetchRadius(requestedNM: 8, appRadiusNM: 25), 25)
        XCTAssertEqual(IntentFlights.fetchRadius(requestedNM: 30, appRadiusNM: 25), 50)
        XCTAssertEqual(IntentFlights.fetchRadius(requestedNM: 400, appRadiusNM: 25), 100)
    }

    // MARK: Entity mapping

    func testEntityMapping() {
        let e = FlightEntity(flight: united(), units: .metric, locale: us)
        XCTAssertEqual(e.id, "a1b2c3")
        XCTAssertEqual(e.title, "UA1543")
        XCTAssertEqual(e.callsign, "UAL1543")
        XCTAssertEqual(e.flightNumber, "UA1543")
        XCTAssertEqual(e.airline, "United Airlines")
        XCTAssertEqual(e.registration, "N37522")
        XCTAssertEqual(e.type, "Boeing 737-800")
        XCTAssertEqual(e.typeCode, "B738")
        XCTAssertEqual(e.origin, "Chicago (ORD)")
        XCTAssertEqual(e.destination, "Denver (DEN)")
        XCTAssertEqual(e.altitude.converted(to: .feet).value, 7_310, accuracy: 0.01)
        XCTAssertEqual(e.speed.converted(to: .knots).value, 250, accuracy: 0.01)
        XCTAssertEqual(e.distance.converted(to: .nauticalMiles).value, 4.2, accuracy: 0.001)
        XCTAssertEqual(e.bearing, 2)
        XCTAssertEqual(e.direction, "north")
        XCTAssertEqual(e.trend, "descending")
        XCTAssertNil(e.situation)
        XCTAssertEqual(e.link, URL(string: "flightdesk://flight/a1b2c3"))
        XCTAssertTrue(e.summary.contains("8 kilometers north"))
        XCTAssertEqual(e.subtitle, "Boeing 737 · ORD → DEN · 7.8 km N · 2,228 m")
    }

    func testEntityForPrivateAircraftHasNoAirlineOrRoute() {
        var f = flight(callsign: "", reg: "N172SP", type: "C172", squawk: "7600")
        f.aircraft = AircraftInfo(model: nil, owner: "Jane Doe")
        let e = FlightEntity(flight: f, units: .imperial)
        XCTAssertNil(e.airline)
        XCTAssertNil(e.origin)
        XCTAssertNil(e.destination)
        XCTAssertEqual(e.type, "C172")
        XCTAssertEqual(e.title, "N172SP")
        XCTAssertEqual(e.situation, "Radio failure · 7600")
    }
}
