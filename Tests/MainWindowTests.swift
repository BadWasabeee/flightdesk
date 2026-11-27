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
}
