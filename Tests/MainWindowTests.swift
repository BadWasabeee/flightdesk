import XCTest

final class MainWindowTests: XCTestCase {

    private func flight(_ hex: String, callsign: String = "", reg: String = "N1", type: String = "B738",
                        alt: Int = 10_000, dst: Double = 10, lat: Double = 36.0, lon: Double = -88.2,
                        track: Double = 330) -> Flight {
        let json = """
        {"hex":"\(hex)","flight":"\(callsign)","r":"\(reg)","t":"\(type)","alt_baro":\(alt),"gs":450,
         "track":\(track),"lat":\(lat),"lon":\(lon),"dst":\(dst),"dir":90}
        """
        return Flight(adsb: try! JSONDecoder().decode(ADSBAircraft.self, from: Data(json.utf8)))!
    }

    private let rsw = Airport(code: "RSW", city: "Fort Myers", lat: 26.54, lon: -81.76)
    private let msp = Airport(code: "MSP", city: "Minneapolis", lat: 44.88, lon: -93.22)
    private let oak = Airport(code: "OAK", city: "Oakland", lat: 37.72, lon: -122.22)
    private let lax = Airport(code: "LAX", city: "Los Angeles", lat: 33.94, lon: -118.41)

    // MARK: Search

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(FlightListFilter.matches(flight("a"), query: ""))
        XCTAssertTrue(FlightListFilter.matches(flight("a"), query: "   "))
    }

    func testMatchesCallsignRegAndTypeCaseInsensitively() {
        let f = flight("a", callsign: "SWA2210", reg: "N8710M", type: "B38M")
        XCTAssertTrue(FlightListFilter.matches(f, query: "swa22"))
        XCTAssertTrue(FlightListFilter.matches(f, query: "n8710"))
        XCTAssertTrue(FlightListFilter.matches(f, query: "b38m"))
        XCTAssertFalse(FlightListFilter.matches(f, query: "UAL"))
    }

    func testMatchesAirlineFlightNumberAndRoute() {
        var f = flight("a", callsign: "SWA2210")
        f.route = RouteInfo(airline: "Southwest Airlines", flightNo: "WN2210", airlineCode: "WN", from: rsw, to: msp)
        XCTAssertTrue(FlightListFilter.matches(f, query: "southwest"))
        XCTAssertTrue(FlightListFilter.matches(f, query: "WN2210"))
        XCTAssertTrue(FlightListFilter.matches(f, query: "msp"))
        XCTAssertTrue(FlightListFilter.matches(f, query: "minneapolis"))
    }

    func testMatchesAircraftOwnerAndModelWithoutRoute() {
        var f = flight("a", callsign: "N123AB", type: "C172")
        f.aircraft = AircraftInfo(model: "Cessna 172 Skyhawk", owner: "Société Aéro Club")
        XCTAssertTrue(FlightListFilter.matches(f, query: "skyhawk"))
        XCTAssertTrue(FlightListFilter.matches(f, query: "societe aero"))   // diacritics ignored
    }

    func testEveryWordMustMatch() {
        let f = flight("a", callsign: "DAL100", type: "A321")
        XCTAssertTrue(FlightListFilter.matches(f, query: "dal a321"))
        XCTAssertFalse(FlightListFilter.matches(f, query: "dal b738"))
    }

    // MARK: Sort

    func testSortsByDistanceThenHex() {
        let list = [flight("c", dst: 5), flight("b", dst: 2), flight("a", dst: 5)]
        XCTAssertEqual(FlightListFilter.apply(list, query: "", sort: .distance).map(\.id), ["b", "a", "c"])
    }

    func testSortsByAltitudeLowestFirstThenDistance() {
        let list = [flight("a", alt: 30_000, dst: 1), flight("b", alt: 2_000, dst: 9), flight("c", alt: 2_000, dst: 3)]
        XCTAssertEqual(FlightListFilter.apply(list, query: "", sort: .altitude).map(\.id), ["c", "b", "a"])
    }

    func testApplyFiltersBeforeSorting() {
        let list = [flight("a", callsign: "UAL1", dst: 3), flight("b", callsign: "DAL2", dst: 1), flight("c", callsign: "UAL3", dst: 2)]
        XCTAssertEqual(FlightListFilter.apply(list, query: "ual", sort: .distance).map(\.id), ["c", "a"])
    }

    // MARK: Merge

    func testMergeFillsMissingDetailsFromKnownFlights() {
        var known = flight("a", callsign: "SWA2210")
        known.route = RouteInfo(from: rsw, to: msp)
        known.aircraft = AircraftInfo(model: "Boeing 737", owner: nil)
        let merged = FlightListFilter.merging([flight("a", callsign: "SWA2210"), flight("b")], known: ["a": known])
        XCTAssertEqual(merged.map(\.id), ["a", "b"])
        XCTAssertEqual(merged[0].route?.to.code, "MSP")
        XCTAssertEqual(merged[0].aircraft?.model, "Boeing 737")
        XCTAssertNil(merged[1].route)
    }

    func testMergeKeepsLivePositionAndDropsImplausibleRoute() {
        var known = flight("a", lat: 30, lon: -80)
        known.route = RouteInfo(from: oak, to: lax)   // nowhere near the live position over Tennessee
        let merged = FlightListFilter.merging([flight("a", alt: 12_000)], known: ["a": known])
        XCTAssertNil(merged[0].route)
        XCTAssertEqual(merged[0].lat, 36.0)
        XCTAssertEqual(merged[0].altitude, 12_000)
    }

    func testMergeDoesNotOverwriteLiveDetails() {
        var live = flight("a")
        live.aircraft = AircraftInfo(model: "Live", owner: nil)
        var known = flight("a")
        known.aircraft = AircraftInfo(model: "Old", owner: nil)
        XCTAssertEqual(FlightListFilter.merging([live], known: ["a": known])[0].aircraft?.model, "Live")
    }

    // MARK: Search & sort additions

    func testMatchesHexAndSquawk() {
        var f = flight("a1b2c3", callsign: "N1")
        f.squawk = "7700"
        XCTAssertTrue(FlightListFilter.matches(f, query: "A1B2C3"))
        XCTAssertTrue(FlightListFilter.matches(f, query: "7700"))
    }

    func testSortsByFlightNumberNaturally() {
        let list = [flight("a", callsign: "UAL10"), flight("b", callsign: "UAL9"), flight("c", callsign: "AAL200")]
        XCTAssertEqual(FlightListFilter.apply(list, query: "", sort: .flight).map(\.callsign), ["AAL200", "UAL9", "UAL10"])
    }

    // MARK: Row text

    func testSubtitlePrefersRouteOverAirline() {
        var f = flight("a", callsign: "SWA2210", type: "B38M")
        f.route = RouteInfo(airline: "Southwest Airlines", flightNo: "WN2210", from: rsw, to: msp)
        XCTAssertEqual(FlightRowText.subtitle(f), "RSW → MSP · B38M")
        var g = flight("b", callsign: "N123AB", type: "C172")
        g.aircraft = AircraftInfo(model: nil, owner: "Aero Club")
        XCTAssertEqual(FlightRowText.subtitle(g), "Aero Club · C172")
        XCTAssertEqual(FlightRowText.subtitle(flight("c", callsign: "N1", type: "")), "")
    }

    func testOperatorNameFallsBackToPrivate() {
        XCTAssertEqual(FlightRowText.operatorName(flight("a", callsign: "N123AB")), "Private / general aviation")
        XCTAssertEqual(FlightRowText.operatorName(flight("a", callsign: "SWA1")), "SWA1")
    }

    func testClimbStateDeadBand() {
        XCTAssertEqual(ClimbState(verticalRate: 301), .climbing)
        XCTAssertEqual(ClimbState(verticalRate: -301), .descending)
        XCTAssertEqual(ClimbState(verticalRate: 250), .level)
    }

    func testVerticalSpeedText() {
        XCTAssertEqual(FlightRowText.verticalSpeed(1_830, units: .imperial), "+1,800 ft/min")
        XCTAssertEqual(FlightRowText.verticalSpeed(-1_000, units: .metric), "−5.1 m/s")
        XCTAssertEqual(FlightRowText.verticalSpeed(100, units: .imperial), "Level")
    }

    func testEmergencySquawk() {
        var f = flight("a")
        XCTAssertNil(FlightRowText.emergency(f))
        f.squawk = "7600"
        XCTAssertEqual(FlightRowText.emergency(f), "Radio failure")
        f.squawk = "1200"
        XCTAssertNil(FlightRowText.emergency(f))
    }

    func testAccessibilityTextSpellsOutUnits() {
        var f = flight("a", callsign: "DAL100", type: "A321", alt: 12_000, dst: 4.25)
        f.bearing = 135
        XCTAssertEqual(FlightRowText.accessibilityLabel(f), "DAL100, A321")
        let value = FlightRowText.accessibilityValue(f, units: .imperial)
        XCTAssertTrue(value.hasPrefix("12,000 feet"), value)
        XCTAssertTrue(value.hasSuffix("nautical miles southeast"), value)
        XCTAssertFalse(value.contains("ft"))
        XCTAssertTrue(FlightRowText.accessibilityValue(f, units: .metric).contains("kilometers"))
    }

    // MARK: Map labels

    private let viewport = MapLabelLayout.Viewport(center: GeoPoint(lat: 42, lon: -88), latitudeDelta: 2, longitudeDelta: 2,
                                                   size: CGSize(width: 800, height: 800))

    private func item(_ id: String, _ lat: Double, _ lon: Double) -> MapLabelLayout.Item {
        MapLabelLayout.Item(id: id, point: GeoPoint(lat: lat, lon: lon), text: "ABC1234")
    }

    func testProjectionPutsCentreInTheMiddle() {
        let p = MapLabelLayout.project(GeoPoint(lat: 42, lon: -88), in: viewport)!
        XCTAssertEqual(p.x, 400, accuracy: 0.5)
        XCTAssertEqual(p.y, 400, accuracy: 0.5)
        let ne = MapLabelLayout.project(GeoPoint(lat: 42.5, lon: -87.5), in: viewport)!
        XCTAssertGreaterThan(ne.x, 400)
        XCTAssertLessThan(ne.y, 400)
        XCTAssertNil(MapLabelLayout.project(GeoPoint(lat: 0, lon: 0), in: .init(center: GeoPoint(lat: 0, lon: 0), latitudeDelta: 0,
                                                                                    longitudeDelta: 1, size: CGSize(width: 1, height: 1))))
    }

    func testFarApartAircraftAreAllLabelled() {
        let items = [item("a", 42, -88), item("b", 42.6, -87.4), item("c", 41.4, -88.6)]
        XCTAssertEqual(MapLabelLayout.labelled(items, in: viewport), ["a", "b", "c"])
    }

    func testOverlappingLabelsKeepTheHigherPriority() {
        // ~0.01° apart is a few points on this map: only the first (nearest) gets a label.
        let items = [item("near", 42, -88), item("far", 42.001, -88.002)]
        XCTAssertEqual(MapLabelLayout.labelled(items, in: viewport), ["near"])
    }

    func testPinnedAndPreferredWin() {
        let items = [item("near", 42, -88), item("far", 42.001, -88.002)]
        XCTAssertEqual(MapLabelLayout.labelled(items, in: viewport, pinned: "far"), ["far"])
        XCTAssertEqual(MapLabelLayout.labelled(items, in: viewport, prefer: ["far"]), ["far"])
    }

    func testOffScreenAircraftAreNotLabelledAndLimitHolds() {
        XCTAssertEqual(MapLabelLayout.labelled([item("away", 50, -70)], in: viewport), [])
        let grid = (0..<10).flatMap { i in (0..<10).map { j in item("\(i)-\(j)", 41.2 + Double(i) * 0.16, -88.8 + Double(j) * 0.16) } }
        XCTAssertEqual(MapLabelLayout.labelled(grid, in: viewport, limit: 5).count, 5)
    }

    func testLabelsAvoidOtherAircraftIcons() {
        // "b" sits right where "a"'s label would go (12 pt below its icon).
        let below = 14.0 / 400   // degrees per point ≈ 2 / 800, so 14 pt ≈ 0.035°
        let items = [item("a", 42, -88), MapLabelLayout.Item(id: "b", point: GeoPoint(lat: 42 - below, lon: -88), text: "X")]
        XCTAssertFalse(MapLabelLayout.labelled(items, in: viewport).contains("a"))
    }
}
