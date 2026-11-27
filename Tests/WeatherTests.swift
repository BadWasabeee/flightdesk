import XCTest

final class WeatherTests: XCTestCase {
    /// Captured from `https://aviationweather.gov/api/data/metar?ids=…&format=json` (Nov 2026), trimmed,
    /// plus a VRB wind, a fractional visibility with vertical visibility, and a report without a category.
    static let metarJSON = """
    [{"icaoId":"EDDM","receiptTime":"2026-11-27T13:56:27.650Z","obsTime":1795787400,"reportTime":"2026-11-27T14:00:00.000Z","temp":0,"dewp":-2,"wdir":40,"wspd":3,"visib":"6+","altim":1020,"qcField":2,"metarType":"METAR","rawOb":"METAR EDDM 271350Z AUTO 04003KT 360V070 9999 FEW008 OVC041 M00/M02 Q1020 TEMPO BKN010","lat":48.348,"lon":11.813,"elev":445,"name":"Munich Intl, BY, DE","cover":"OVC","clouds":[{"cover":"FEW","base":800},{"cover":"OVC","base":4100}],"fltCat":"VFR"},
     {"icaoId":"KORD","receiptTime":"2026-11-27T13:54:08.565Z","obsTime":1795787460,"reportTime":"2026-11-27T14:00:00.000Z","temp":3.3,"dewp":-1.1,"wdir":320,"wspd":11,"wgst":18,"visib":"10+","altim":1004.1,"slp":1004.4,"qcField":12,"metarType":"METAR","rawOb":"METAR KORD 271351Z 32011G18KT 10SM FEW025 BKN060 OVC075 03/M01 A2965 RMK AO2 SLP044 T00331011 $","lat":41.9602,"lon":-87.9316,"elev":202,"name":"Chicago/O'Hare Intl, IL, US","cover":"OVC","clouds":[{"cover":"FEW","base":2500},{"cover":"BKN","base":6000},{"cover":"OVC","base":7500}],"fltCat":"VFR"},
     {"icaoId":"KBEH","obsTime":1795788000,"temp":2.8,"dewp":1.7,"wdir":"VRB","wspd":5,"wgst":17,"visib":6,"altim":1001.8,"rawOb":"SPECI KBEH 271400Z AUTO VRB05G17KT 6SM UP BR BKN011 OVC017 03/02 A2958 RMK AO2 P0001 T00280017","clouds":[{"cover":"BKN","base":1100},{"cover":"OVC","base":1700}],"fltCat":"MVFR"},
     {"icaoId":"KMFR","obsTime":1795788420,"temp":10,"dewp":9.4,"wdir":0,"wspd":0,"visib":0.5,"altim":1024.7,"rawOb":"SPECI KMFR 271407Z 00000KT 1/2SM R14/P6000FT FG VV003 10/09 A3025 RMK AO2 T01000094","clouds":[{"cover":"OVX","base":300}]},
     {"icaoId":"CZCR","obsTime":1795788000,"temp":-2.8,"dewp":-7,"wdir":150,"wspd":1,"visib":null,"altim":null,"rawOb":"METAR CZCR 271400Z AUTO 15001KT M03/M07 RMK AO1 SLP172 T10281070 58032","clouds":[],"fltCat":null},
     {"icaoId":"BAD ID","obsTime":1795788000,"rawOb":"junk"},
     {"no":"station"}]
    """

    static let tafJSON = """
    [{"icaoId":"KORD","dbPopTime":"2026-11-27T13:33:01.612Z","bulletinTime":"2026-11-27T13:32:00.000Z","issueTime":"2026-11-27T13:32:00.000Z","validTimeFrom":1795788000,"validTimeTo":1795888800,"rawTAF":"TAF KORD 271332Z 2714/2818 33013G23KT P6SM -SHRA SCT035 OVC060 FM271600 32012G22KT P6SM BKN100 FM272200 29008KT P6SM BKN250 PROB30 TEMPO 2800/2804 BKN030","mostRecent":1,"fcsts":[]}]
    """

    private func decoded() throws -> [String: Metar] {
        let list = try WeatherDecoder.metars(from: Data(Self.metarJSON.utf8))
        return Dictionary(uniqueKeysWithValues: list.map { ($0.station, $0) })
    }

    // MARK: Decoding

    func testDecodesMetars() throws {
        let m = try decoded()
        XCTAssertEqual(Set(m.keys), ["EDDM", "KORD", "KBEH", "KMFR", "CZCR"])

        let ord = try XCTUnwrap(m["KORD"])
        XCTAssertEqual(ord.observed, Date(timeIntervalSince1970: 1795787460))
        XCTAssertEqual(ord.wind, SurfaceWind(directionDeg: 320, speedKt: 11, gustKt: 18))
        XCTAssertEqual(ord.visibility, WeatherVisibility(statuteMiles: 10, orMore: true))
        XCTAssertEqual(ord.ceilingFt, 6_000)
        XCTAssertEqual(ord.clouds.count, 3)
        XCTAssertEqual(ord.temperatureC, 3.3)
        XCTAssertEqual(ord.dewpointC, -1.1)
        XCTAssertEqual(try XCTUnwrap(ord.altimeterInHg), 29.65, accuracy: 0.001)   // exact from A2965
        XCTAssertEqual(try XCTUnwrap(ord.altimeterHPa), 1004.1, accuracy: 0.1)
        XCTAssertEqual(ord.category, .vfr)
        XCTAssertTrue(ord.raw.hasPrefix("METAR KORD 271351Z"))

        let eddm = try XCTUnwrap(m["EDDM"])
        XCTAssertEqual(eddm.altimeterHPa, 1020)                                       // exact from Q1020
        XCTAssertEqual(try XCTUnwrap(eddm.altimeterInHg), 30.12, accuracy: 0.01)
        XCTAssertEqual(eddm.wind?.variableFromDeg, 360 % 360)
        XCTAssertEqual(eddm.wind?.variableToDeg, 70)
        XCTAssertEqual(eddm.ceilingFt, 4_100)
        XCTAssertEqual(eddm.temperatureC, 0)

        let beh = try XCTUnwrap(m["KBEH"])
        XCTAssertNil(beh.wind?.directionDeg)
        XCTAssertEqual(beh.wind?.isVariable, true)
        XCTAssertEqual(beh.wind?.gustKt, 17)
        XCTAssertEqual(beh.category, .mvfr)

        let mfr = try XCTUnwrap(m["KMFR"])
        XCTAssertEqual(mfr.visibility?.statuteMiles, 0.5)
        XCTAssertEqual(mfr.ceilingFt, 300)                                            // vertical visibility
        XCTAssertEqual(mfr.category, .lifr)                                           // computed: no fltCat
        XCTAssertEqual(mfr.wind?.isCalm, true)

        let czcr = try XCTUnwrap(m["CZCR"])
        XCTAssertNil(czcr.category)                                                   // nothing to go on
        XCTAssertNil(czcr.visibility)
        XCTAssertNil(czcr.altimeterHPa)
    }

    func testEmptyResponses() throws {
        XCTAssertEqual(try WeatherDecoder.metars(from: Data()), [])                   // HTTP 204
        XCTAssertEqual(try WeatherDecoder.metars(from: Data("[]".utf8)), [])
        XCTAssertThrowsError(try WeatherDecoder.metars(from: Data("<html>".utf8)))
    }

    func testDecodesTaf() throws {
        let t = try XCTUnwrap(try WeatherDecoder.tafs(from: Data(Self.tafJSON.utf8)).first)
        XCTAssertEqual(t.station, "KORD")
        XCTAssertEqual(t.validFrom, Date(timeIntervalSince1970: 1795788000))
        XCTAssertNotNil(t.issued)
        XCTAssertEqual(WeatherFormat.tafLines(t.raw), [
            "TAF KORD 271332Z 2714/2818 33013G23KT P6SM -SHRA SCT035 OVC060",
            "FM271600 32012G22KT P6SM BKN100",
            "FM272200 29008KT P6SM BKN250",
            "PROB30 TEMPO 2800/2804 BKN030",
        ])
    }

    func testVisibilityText() {
        XCTAssertEqual(WeatherDecoder.visibility(text: "10+"), WeatherVisibility(statuteMiles: 10, orMore: true))
        XCTAssertEqual(WeatherDecoder.visibility(text: "P6SM"), WeatherVisibility(statuteMiles: 6, orMore: true))
        XCTAssertEqual(WeatherDecoder.visibility(text: "1 1/2"), WeatherVisibility(statuteMiles: 1.5))
        XCTAssertEqual(WeatherDecoder.visibility(text: "M1/4"), WeatherVisibility(statuteMiles: 0.25))
        XCTAssertNil(WeatherDecoder.visibility(text: "lots"))
    }

    func testStationCodes() {
        XCTAssertEqual(AirportCode.icao(" kord "), "KORD")
        XCTAssertEqual(AirportCode.icao("K1G4"), "K1G4")
        XCTAssertNil(AirportCode.icao("1ORD"))
        XCTAssertNil(AirportCode.icao("KOR"))
        XCTAssertNil(AirportCode.icao("KO,D"))
        XCTAssertNil(AirportCode.icao("KÖRD"))
        XCTAssertEqual(WeatherStation.icao(code: "ORD"), "KORD")
        XCTAssertEqual(WeatherStation.icao(code: "MUC"), "EDDM")
        XCTAssertEqual(WeatherService.sanitized(["kord", "KORD", "bad id", "EDDM"]), ["KORD", "EDDM"])
    }

    // MARK: Flight category

    func testFlightCategory() {
        XCTAssertNil(FlightCategory.from(ceilingFt: nil, visibilitySM: nil))
        XCTAssertEqual(FlightCategory.from(ceilingFt: nil, visibilitySM: 10), .vfr)
        XCTAssertEqual(FlightCategory.from(ceilingFt: 3_100, visibilitySM: 6), .vfr)
        XCTAssertEqual(FlightCategory.from(ceilingFt: 3_000, visibilitySM: 10), .mvfr)
        XCTAssertEqual(FlightCategory.from(ceilingFt: 1_000, visibilitySM: 10), .mvfr)
        XCTAssertEqual(FlightCategory.from(ceilingFt: nil, visibilitySM: 5), .mvfr)
        XCTAssertEqual(FlightCategory.from(ceilingFt: 999, visibilitySM: 10), .ifr)
        XCTAssertEqual(FlightCategory.from(ceilingFt: 5_000, visibilitySM: 2.5), .ifr)
        XCTAssertEqual(FlightCategory.from(ceilingFt: 499, visibilitySM: 10), .lifr)
        XCTAssertEqual(FlightCategory.from(ceilingFt: 5_000, visibilitySM: 0.75), .lifr)
        // The worse of the two decides.
        XCTAssertEqual(FlightCategory.from(ceilingFt: 800, visibilitySM: 4), .ifr)
    }

    // MARK: Wind components

    func testWindComponents() throws {
        // Straight down the runway.
        var c = try XCTUnwrap(WindComponents.of(SurfaceWind(directionDeg: 280, speedKt: 10), runwayHeading: 280))
        XCTAssertEqual(c.headwindKt, 10, accuracy: 1e-9)
        XCTAssertEqual(c.crosswindKt, 0, accuracy: 1e-9)
        // 90° from the right.
        c = try XCTUnwrap(WindComponents.of(SurfaceWind(directionDeg: 10, speedKt: 12, gustKt: 20), runwayHeading: 280))
        XCTAssertEqual(c.headwindKt, 0, accuracy: 1e-9)
        XCTAssertEqual(c.crosswindKt, 12, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(c.gustCrosswindKt), 20, accuracy: 1e-9)
        // 30° from the left: head = 20 cos 30, cross = −20 sin 30.
        c = try XCTUnwrap(WindComponents.of(SurfaceWind(directionDeg: 250, speedKt: 20), runwayHeading: 280))
        XCTAssertEqual(c.headwindKt, 17.32, accuracy: 0.01)
        XCTAssertEqual(c.crosswindKt, -10, accuracy: 1e-9)
        // Tailwind.
        c = try XCTUnwrap(WindComponents.of(SurfaceWind(directionDeg: 100, speedKt: 8), runwayHeading: 280))
        XCTAssertEqual(c.headwindKt, -8, accuracy: 1e-9)
        XCTAssertEqual(WeatherFormat.components(c, units: .imperial), "Tailwind 8 kt · crosswind 0 kt")
        // Variable: no components; calm: zero.
        XCTAssertNil(WindComponents.of(SurfaceWind(directionDeg: nil, speedKt: 5), runwayHeading: 280))
        XCTAssertEqual(WindComponents.of(SurfaceWind(directionDeg: nil, speedKt: 0), runwayHeading: 280),
                       WindComponents(headwindKt: 0, crosswindKt: 0))
        XCTAssertEqual(WeatherFormat.components(WindComponents(headwindKt: 8.2, crosswindKt: -5.4, gustCrosswindKt: -9), units: .imperial),
                       "Headwind 8 kt · crosswind 5 kt from the left (gusts 9)")
    }

    func testComponentsForRunwayInUse() throws {
        let ord = try XCTUnwrap(try decoded()["KORD"])
        let airport = Airport(code: "ORD", city: "Chicago", lat: 41.98, lon: -87.9)
        let c = AirportConditions(airport: airport, station: "KORD", metar: ord)
        let end = RunwayEnd(ident: "28C", threshold: GeoPoint(lat: 41.98, lon: -87.89), heading: 270)
        let far = RunwayEnd(ident: "10C", threshold: GeoPoint(lat: 41.98, lon: -87.93), heading: 90)
        let comps = try XCTUnwrap(c.components(runway: "28C") { ident, _ in ident == "28C" ? (end, far) : nil })
        XCTAssertEqual(comps.headwindKt, 11 * cos(50 * .pi / 180), accuracy: 1e-9)
        XCTAssertEqual(comps.crosswindKt, 11 * sin(50 * .pi / 180), accuracy: 1e-9)
        XCTAssertNil(c.components(runway: "09L") { _, _ in nil })
        XCTAssertTrue(c.matches(Airport(code: "KORD", city: "", lat: 0, lon: 0)))
    }

    func testAltimeterFallbackUsesNearbyAirport() throws {
        let m = try decoded()
        let ord = AirportConditions(airport: Airport(code: "ORD", city: "", lat: 41.98, lon: -87.9), station: "KORD", metar: m["KORD"])
        let muc = AirportConditions(airport: Airport(code: "MUC", city: "", lat: 48.35, lon: 11.79), station: "EDDM", metar: m["EDDM"])
        XCTAssertEqual(try XCTUnwrap(AirportConditions.altimeterHPa(near: GeoPoint(lat: 48.2, lon: 11.5), in: [ord, muc])), 1020, accuracy: 0.01)
        XCTAssertNil(AirportConditions.altimeterHPa(near: GeoPoint(lat: 60, lon: 0), in: [ord, muc]))
    }

    // MARK: Formatting

    func testFormatting() throws {
        let m = try decoded()
        let ord = try XCTUnwrap(m["KORD"]), eddm = try XCTUnwrap(m["EDDM"]), mfr = try XCTUnwrap(m["KMFR"])
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(WeatherFormat.wind(try XCTUnwrap(ord.wind), units: .imperial), "320° 11G18 kt")
        XCTAssertEqual(WeatherFormat.wind(try XCTUnwrap(ord.wind), units: .metric), "320° 20G33 km/h")
        XCTAssertEqual(WeatherFormat.wind(try XCTUnwrap(eddm.wind), units: .imperial), "040° 3 kt (360°–070°)")
        XCTAssertEqual(WeatherFormat.wind(try XCTUnwrap(mfr.wind), units: .imperial), "Calm")
        XCTAssertEqual(WeatherFormat.wind(try XCTUnwrap(m["KBEH"]?.wind), units: .imperial), "VRB 5G17 kt")
        XCTAssertEqual(WeatherFormat.visibility(try XCTUnwrap(ord.visibility), units: .imperial), "10+ SM")
        XCTAssertEqual(WeatherFormat.visibility(try XCTUnwrap(eddm.visibility), units: .metric), "10+ km")
        XCTAssertEqual(WeatherFormat.visibility(try XCTUnwrap(mfr.visibility), units: .imperial), "1/2 SM")
        XCTAssertEqual(WeatherFormat.visibility(try XCTUnwrap(mfr.visibility), units: .metric, locale: en), "800 m")
        XCTAssertEqual(WeatherFormat.statuteMiles(2.5), "2 1/2")
        XCTAssertEqual(WeatherFormat.ceiling(ord, units: .imperial, locale: en), "BKN 6,000 ft")
        XCTAssertEqual(WeatherFormat.ceiling(mfr, units: .imperial, locale: en), "VV 300 ft")
        XCTAssertEqual(WeatherFormat.ceiling(ord, units: .metric, locale: en), "BKN 1,829 m")
        XCTAssertEqual(WeatherFormat.ceiling(try XCTUnwrap(m["CZCR"]), units: .imperial), "None")
        XCTAssertEqual(WeatherFormat.temperature(ord), "3° / −1° C")
        XCTAssertEqual(WeatherFormat.altimeter(ord, units: .imperial), "29.65 inHg · 1004 hPa")
        XCTAssertEqual(WeatherFormat.altimeter(eddm, units: .metric), "1020 hPa")
        let obs = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(WeatherFormat.age(obs, now: obs.addingTimeInterval(30)), "just now")
        XCTAssertEqual(WeatherFormat.age(obs, now: obs.addingTimeInterval(12 * 60)), "12 m ago")
        XCTAssertEqual(WeatherFormat.age(obs, now: obs.addingTimeInterval(65 * 60)), "1 h 5 m ago")
    }

    // MARK: Cache

    /// A settable clock and a counting fetcher for the cache tests.
    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 1795787500)
        private var _calls: [(WeatherService.Product, [String])] = []
        var delay: Duration = .zero

        var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
        var calls: [(WeatherService.Product, [String])] { lock.lock(); defer { lock.unlock() }; return _calls }
        func advance(_ s: TimeInterval) { lock.lock(); _now += s; lock.unlock() }
        func record(_ p: WeatherService.Product, _ ids: [String]) { lock.lock(); _calls.append((p, ids)); lock.unlock() }

        func service() -> WeatherService {
            WeatherService(directory: nil, fetcher: { [self] product, ids in
                record(product, ids)
                if delay > .zero { try await Task.sleep(for: delay) }
                return Data((product == .metar ? WeatherTests.metarJSON : WeatherTests.tafJSON).utf8)
            }, now: { [self] in now })
        }
    }

    func testMetarCacheLifetime() async {
        let h = Harness()
        let service = h.service()
        var r = await service.metars(["KORD", "EDDM"])
        XCTAssertEqual(Set(r.keys), ["KORD", "EDDM"])
        XCTAssertEqual(h.calls.count, 1)
        XCTAssertEqual(h.calls.first?.1, ["KORD", "EDDM"])                            // one batched request

        h.advance(9 * 60)
        r = await service.metars(["EDDM", "KORD"])
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(h.calls.count, 1)                                               // still fresh

        h.advance(2 * 60)                                                              // 11 minutes
        _ = await service.metars(["KORD"])
        XCTAssertEqual(h.calls.count, 2)
        XCTAssertEqual(h.calls.last?.1, ["KORD"])                                      // only the stale one

        // Stations without a report are cached as "none" too.
        _ = await service.metars(["KZZZ"])
        _ = await service.metars(["KZZZ"])
        XCTAssertEqual(h.calls.count, 3)
    }

    func testTafCacheLifetime() async {
        let h = Harness()
        let service = h.service()
        var r = await service.tafs(["KORD"])
        XCTAssertNotNil(r["KORD"])
        h.advance(29 * 60)
        r = await service.tafs(["KORD"])
        XCTAssertNotNil(r["KORD"])
        XCTAssertEqual(h.calls.count, 1)
        h.advance(2 * 60)
        _ = await service.tafs(["KORD"])
        XCTAssertEqual(h.calls.count, 2)
        XCTAssertTrue(h.calls.allSatisfy { $0.0 == .taf })
    }

    func testConcurrentRequestsShareOneFetch() async {
        let h = Harness()
        h.delay = .milliseconds(150)
        let service = h.service()
        async let a = service.metars(["KORD"])
        async let b = service.metars(["KORD"])
        async let c = service.metars(["kord", "EDDM"])
        let results = await [a, b, c]
        XCTAssertTrue(results.allSatisfy { $0["KORD"] != nil })
        XCTAssertNotNil(results[2]["EDDM"])
        // KORD is fetched once however the calls interleave; EDDM at most once more.
        let kordFetches = h.calls.filter { $0.1.contains("KORD") }.count
        XCTAssertEqual(kordFetches, 1)
        XCTAssertLessThanOrEqual(h.calls.count, 2)
    }

    func testPerMinuteCap() async {
        let h = Harness()
        let service = WeatherService(directory: nil, fetcher: { product, ids in
            h.record(product, ids)
            return nil
        }, now: { h.now }, minuteLimit: 2)
        _ = await service.metars(["KAAA"])
        _ = await service.metars(["KBBB"])
        _ = await service.metars(["KCCC"])                                             // over the cap: skipped
        XCTAssertEqual(h.calls.count, 2)
        h.advance(61)
        _ = await service.metars(["KCCC"])
        XCTAssertEqual(h.calls.count, 3)
    }

    func testServiceRegisteredInBudget() {
        XCTAssertEqual(ApiService(host: "aviationweather.gov"), .aviationWeather)
        XCTAssertLessThanOrEqual(ApiService.aviationWeather.minuteLimit ?? .max, 100)
    }
}
