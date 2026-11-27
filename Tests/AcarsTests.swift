import XCTest

/// ACARS from Airframes.io: wire decoding, current-flight selection, label decoding, OOOI,
/// route fixes, positions, copy merging, noise filtering, the polling policy and the route hint.
///
/// Fixtures are trimmed from real Airframes.io responses (November 2026) for N114DU (A03B6D),
/// with feeder ids, signal details and other per-station fields removed.
final class AcarsTests: XCTestCase {

    private static func date(_ iso: String) -> Date {
        try! Date(iso, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// `/v1/airframes/12696`: four of its 1,481 flights, plus a malformed entry. Note the
    /// DL1343 record carrying the next leg's callsign (DAL2855) in `flightIcao`.
    private let airframeJSON = #"""
    {"id":12696,"tail":"N114DU","icao":"A03B6D","iata":null,"icaoType":"BCS1","flights":[
     {"id":5422845869,"flight":"DL835","flightIcao":"DAL536","flightIata":"DL835","status":"radio-silence","departingAirport":null,"destinationAirport":null,"latitude":41.679886,"longitude":-79.225034,"altitude":37000,"track":73,"messagesCount":0,"createdAt":"2025-01-03T23:16:32.977Z","updatedAt":"2025-01-05T16:21:02.838Z"},
     {"id":5559078825,"flight":"DL2795","flightIcao":"DAL1343","flightIata":"DL2795","status":"radio-silence","departingAirport":"KMSO","destinationAirport":"KSLC","latitude":40.748663,"longitude":-111.969535,"altitude":5825,"track":173,"messagesCount":2,"createdAt":"2026-11-26T15:21:21.967Z","updatedAt":"2026-11-26T17:05:57.689Z"},
     {"id":5559085878,"flight":"DL1343","flightIcao":"DAL2855","flightIata":"DL1343","status":"radio-silence","departingAirport":null,"destinationAirport":null,"latitude":40.804573,"longitude":-111.976776,"altitude":4600,"track":352,"messagesCount":196,"createdAt":"2026-11-26T16:55:20.304Z","updatedAt":"2026-11-27T00:56:58.788Z"},
     {"id":5559112489,"flight":"DL2855","flightIcao":"DAL2855","flightIata":"DL2855","status":"in-flight","departingAirport":null,"destinationAirport":null,"latitude":42.165388,"longitude":-86.279467,"altitude":38600,"track":93,"messagesCount":25,"createdAt":"2026-11-27T00:47:04.303Z","updatedAt":"2026-11-27T03:28:07.444Z"},
     {"id":"not-a-number","flight":"XX1"},
     null
    ],"createdAt":"2019-11-22T07:19:08.152Z","updatedAt":"2026-11-16T00:34:34.984Z"}
    """#

    /// `/v1/flights/5559085878` (DL1343 AUS→SLC; the airports, null in the record, are filled in
    /// from the messages' own text). The same transmissions arrive from several receivers, with
    /// and without the onboard-system prefix.
    private let flightJSON = #"""
    {"id":"5559085878","flight":"DL1343","flightIcao":"DAL2855","flightIata":"DL1343","status":"radio-silence","phase":"airborne",
     "departingAirport":"KAUS","destinationAirport":"KSLC","messagesCount":196,"events":[],"messages":[
     {"id":8240286943,"timestamp":"2026-11-27T00:46:21.906Z","label":null,"text":null,"sourceType":"vdl","source":"dumpvdl2","linkDirection":null,"fromHex":"A03B6D","toHex":"1150EA","blockId":null},
     {"id":8239890977,"timestamp":"2026-11-26T22:54:54.290Z","label":"H1","text":"221C02  26Nov2026 22:54:35 CRUISE   0\r\n","sourceType":"vdl","source":"dumpvdl2","linkDirection":null,"fromHex":"A03B6D","toHex":"1150EA","blockId":"5","tail":"N114DU","flightNumber":"DL1343"},
     {"id":8239235739,"timestamp":"2026-11-26T20:55:20.825Z","label":"Q0","text":null,"sourceType":"vdl","source":"vdlm2dec","linkDirection":null,"fromHex":null,"toHex":"11546a","blockId":"9"},
     {"id":8239235223,"timestamp":"2026-11-26T20:55:16.187Z","label":"Q0","text":null,"sourceType":"vdl","source":"vdlm2dec","linkDirection":null,"fromHex":null,"toHex":"11546a","blockId":"9"},
     {"id":8239104791,"timestamp":"2026-11-26T20:37:27.461Z","label":"H1","text":"USADCXA.DR1.N114DU92B4","sourceType":"vdl","source":"dumpvdl2","linkDirection":null,"fromHex":"A03B6D","toHex":"11213A","blockId":"6"},
     {"id":8239107092,"timestamp":"2026-11-26T20:37:24.652Z","label":"H1","text":"232A03  26Nov2026 20:37:05 CRUISE   0\r\n","sourceType":"vdl","source":"dumpvdl2","linkDirection":null,"fromHex":"A03B6D","toHex":"11213A","blockId":"7"},
     {"id":8239107074,"timestamp":"2026-11-26T20:37:24.558Z","label":"H1","text":"#CFB232A03  26Nov2026 20:37:05 CRUISE   0\r\n","sourceType":"vdl","source":"vdlm2dec","linkDirection":null,"fromHex":null,"toHex":"11213a","blockId":"7"},
     {"id":8239104818,"timestamp":"2026-11-26T20:37:04.874Z","label":"H1","text":"USADCXA.DR1.N114DU92B4","sourceType":"vdl","source":"dumpvdl2","linkDirection":null,"fromHex":"A03B6D","toHex":"11213A","blockId":"6"},
     {"id":8239104783,"timestamp":"2026-11-26T20:37:04.760Z","label":"H1","text":"#M1B/BA USADCXA.DR1.N114DU92B4","sourceType":"vdl","source":"vdlm2dec","linkDirection":null,"fromHex":null,"toHex":"11213a","blockId":"6"},
     {"id":8239104569,"timestamp":"2026-11-26T20:37:03.072Z","label":"_d","text":null,"sourceType":"vdl","source":"vdlm2dec","linkDirection":null,"fromHex":null,"toHex":"11213a","blockId":"5"},
     {"id":1,"label":"H1","text":"no timestamp: skipped"}
    ],"createdAt":"2026-11-26T16:55:20.304Z","updatedAt":"2026-11-27T00:56:58.788Z"}
    """#

    private func flights() throws -> [AirframesAPI.FlightSummary] {
        try XCTUnwrap(AirframesAPI.decode(AirframesAPI.Airframe.self, from: Data(airframeJSON.utf8))?.flights?.elements)
    }

    private func flight() throws -> AcarsFlight {
        let f = try XCTUnwrap(AirframesAPI.decode(AirframesAPI.Flight.self, from: Data(flightJSON.utf8)))
        return AcarsFlight(f, aircraftHex: "a03b6d")
    }

    private func message(label: String?, text: String?, at iso: String = "2026-11-27T03:34:07.000Z",
                         sourceType: String = "vdl", link: String? = nil, from: String? = nil, to: String? = nil,
                         block: String? = nil, id: Int = 1) throws -> AcarsMessage {
        var json: [String: Any] = ["id": id, "timestamp": iso, "sourceType": sourceType]
        json["label"] = label
        json["text"] = text
        json["linkDirection"] = link
        json["fromHex"] = from
        json["toHex"] = to
        json["blockId"] = block
        let data = try JSONSerialization.data(withJSONObject: json)
        return AcarsMessage(try AirframesAPI.decoder().decode(AirframesAPI.Message.self, from: data), aircraftHex: "a03b6d")
    }

    // MARK: Wire format

    func testDecodesAirframeSkippingMalformedFlights() throws {
        let a = try XCTUnwrap(AirframesAPI.decode(AirframesAPI.Airframe.self, from: Data(airframeJSON.utf8)))
        XCTAssertEqual(a.id, 12696)
        let list = try flights()
        XCTAssertEqual(list.map(\.id), [5422845869, 5559078825, 5559085878, 5559112489])
        XCTAssertEqual(list[3].updatedAt, Self.date("2026-11-27T03:28:07.444Z"))
        XCTAssertEqual(list[1].departingAirport, "KMSO")
    }

    func testEmptyBodyMeansNotFound() throws {
        XCTAssertNil(try AirframesAPI.decode(AirframesAPI.Airframe.self, from: Data()))
        XCTAssertNil(try AirframesAPI.decode(AirframesAPI.Airframe.self, from: Data(" \n".utf8)))
    }

    func testDecodesFlightWithStringID() throws {
        let f = try flight()
        XCTAssertEqual(f.id, 5559085878)
        XCTAssertEqual(f.flightNumber, "DL1343")
        XCTAssertEqual(f.phase, "airborne")
        XCTAssertEqual(f.messagesCount, 196)
        XCTAssertEqual(f.departingAirport?.code, "AUS")
        XCTAssertEqual(f.destinationAirport?.code, "SLC")
    }

    // MARK: Copies and noise

    func testMergesCopiesFromSeveralReceiversNewestFirst() throws {
        let f = try flight()
        // 10 decodable messages: two Q0 copies, two CFB copies and three USADCXA copies collapse.
        XCTAssertEqual(f.messages.count, 6)
        XCTAssertEqual(f.messages.map(\.time), f.messages.map(\.time).sorted(by: >))
        let cfb = try XCTUnwrap(f.messages.first { $0.text.contains("232A03") })
        XCTAssertEqual(cfb.text, "#CFB232A03  26Nov2026 20:37:05 CRUISE   0", "keeps the fuller copy, trailing CR/LF removed")
        XCTAssertEqual(cfb.direction, .downlink)
        let dr1 = try XCTUnwrap(f.messages.first { $0.text.contains("USADCXA") })
        XCTAssertEqual(dr1.time, Self.date("2026-11-26T20:37:04.760Z"), "first heard")
        XCTAssertEqual(dr1.plainLabel, "Datalink message")
        XCTAssertEqual(dr1.link, "VDL2")
    }

    func testNoiseIsHiddenUnlessShowingAll() throws {
        let f = try flight()
        let visible = f.visibleMessages(showAll: false)
        XCTAssertEqual(visible.count, 3)
        XCTAssertTrue(visible.allSatisfy { $0.label == "H1" })
        XCTAssertEqual(f.visibleMessages(showAll: true).count, 6)
        let noise = f.messages.filter(\.isNoise)
        XCTAssertEqual(Set(noise.map(\.plainLabel)), ["Link frame", "Link test", "Keep-alive"])
        // An H1 with no text has nothing to read either.
        XCTAssertTrue(try message(label: "H1", text: "  \r\n").isNoise)
        XCTAssertFalse(try message(label: "H1", text: "RESREQ/AK,1158AF6").isNoise)
    }

    // MARK: Current flight

    private let now = AcarsTests.date("2026-11-27T03:30:00.000Z")
    /// Over southern Michigan, where DL2855 SLC→CLE was.
    private let michigan = GeoPoint(lat: 42.17, lon: -86.2)

    func testPicksFlightByScheduledNumber() throws {
        let pick = AcarsFlightMatcher.current(in: try flights(), callsign: "DAL2855", flightNumber: "DL2855",
                                              position: michigan, now: now)
        XCTAssertEqual(pick?.id, 5559112489)
    }

    func testCallsignMatchIgnoresRecordWhoseNumberContradictsIt() throws {
        // Without a scheduled number, DAL2855 matches two records by callsign; DL1343's flight
        // number contradicts it, so only the real DL2855 record counts.
        let list = try flights()
        XCTAssertEqual(AcarsFlightMatcher.current(in: list, callsign: "DAL2855", flightNumber: nil, position: michigan, now: now)?.id,
                       5559112489)
        // Before the new leg's record exists, the previous leg must not be shown instead.
        let previousOnly = list.filter { $0.id != 5559112489 }
        XCTAssertNil(AcarsFlightMatcher.current(in: previousOnly, callsign: "DAL2855", flightNumber: nil, position: michigan, now: now))
    }

    func testOldRecordsAreNotCurrent() throws {
        let tomorrow = now.addingTimeInterval(20 * 3_600)
        XCTAssertNil(AcarsFlightMatcher.current(in: try flights(), callsign: "DAL2855", flightNumber: "DL2855",
                                                position: michigan, now: tomorrow))
    }

    func testRecencyFallbackNeedsFreshInFlightRecordNearby() {
        let unnumbered = AirframesAPI.FlightSummary(id: 7, flight: nil, flightIcao: nil, flightIata: nil, status: "in-flight",
                                                    latitude: 42.0, longitude: -86.5, updatedAt: now.addingTimeInterval(-600))
        XCTAssertEqual(AcarsFlightMatcher.current(in: [unnumbered], callsign: "DAL2855", flightNumber: "DL2855",
                                                  position: michigan, now: now)?.id, 7)
        // Far away, stale, or not in flight: not the same flight.
        XCTAssertNil(AcarsFlightMatcher.current(in: [unnumbered], callsign: "DAL2855", flightNumber: "DL2855",
                                                position: GeoPoint(lat: 25.8, lon: -80.3), now: now))
        XCTAssertNil(AcarsFlightMatcher.current(in: [unnumbered], callsign: "DAL2855", flightNumber: "DL2855",
                                                position: michigan, now: now.addingTimeInterval(2 * 3_600)))
        let parked = AirframesAPI.FlightSummary(id: 8, flight: nil, flightIcao: nil, flightIata: nil, status: "radio-silence",
                                                latitude: 42.0, longitude: -86.5, updatedAt: now.addingTimeInterval(-600))
        XCTAssertNil(AcarsFlightMatcher.current(in: [parked], callsign: "DAL2855", flightNumber: "DL2855", position: michigan, now: now))
        // A fresh record for a different flight number is never picked by recency.
        let other = AirframesAPI.FlightSummary(id: 9, flight: "GK108", flightIcao: "JJP115", flightIata: "GK108", status: "in-flight",
                                               latitude: 42.0, longitude: -86.5, updatedAt: now.addingTimeInterval(-600))
        XCTAssertNil(AcarsFlightMatcher.current(in: [other], callsign: "JJP115", flightNumber: "GK115", position: michigan, now: now))
    }

    func testFlightNumbersIgnoreLeadingZeros() {
        XCTAssertEqual(AcarsFlightMatcher.iata("DL0536"), AcarsFlightMatcher.iata("DL536"))
        XCTAssertEqual(AcarsFlightMatcher.iata("AI06SL")?.suffix, "6SL")
        XCTAssertEqual(AcarsFlightMatcher.iata("9E5393")?.airline, "9E")
        XCTAssertNil(AcarsFlightMatcher.iata("DAL2855"), "a callsign isn't an IATA flight number")
        XCTAssertEqual(AcarsFlightMatcher.icaoSuffix("DAL0536"), "536")
    }

    // MARK: Labels

    func testPlainLabels() {
        XCTAssertEqual(AcarsDecoder.plainLabel("H1", text: "REQPWI/TS221328,261126/WQ410.390:PUMAL.XEPLA"), "Wind data request")
        XCTAssertEqual(AcarsDecoder.plainLabel("H1", text: "#M1BPOSN47144W122283,BREVE,033304,100"), "Position report")
        XCTAssertEqual(AcarsDecoder.plainLabel("H1", text: "PWI/WD410,N47233E000445,349059"), "Wind data")
        XCTAssertEqual(AcarsDecoder.plainLabel("H1", text: "REQPOS037B"), "Position request")
        XCTAssertEqual(AcarsDecoder.plainLabel("H1", text: "RESREQ/AK,1158AF6"), "Acknowledgement")
        XCTAssertEqual(AcarsDecoder.plainLabel("H1", text: "- #M1B/BA USADCXA.DR1.N114DU92B4"), "Datalink message")
        XCTAssertEqual(AcarsDecoder.plainLabel("QA", text: ""), "Out report")
        XCTAssertEqual(AcarsDecoder.plainLabel("QB", text: ""), "Off report")
        XCTAssertEqual(AcarsDecoder.plainLabel("QC", text: ""), "On report")
        XCTAssertEqual(AcarsDecoder.plainLabel("QD", text: ""), "In report")
        XCTAssertEqual(AcarsDecoder.plainLabel("_d", text: ""), "Keep-alive")
        XCTAssertEqual(AcarsDecoder.plainLabel("Q0", text: ""), "Link test")
        XCTAssertEqual(AcarsDecoder.plainLabel("5Z", text: ""), "Airline ops")
        XCTAssertEqual(AcarsDecoder.plainLabel("80", text: ""), "Position / progress report")
        XCTAssertEqual(AcarsDecoder.plainLabel("B6", text: ""), "ADS-C report")
        XCTAssertEqual(AcarsDecoder.plainLabel("B1", text: ""), "Oceanic clearance request")
        XCTAssertEqual(AcarsDecoder.plainLabel("AA", text: ""), "ATC datalink (CPDLC)")
        XCTAssertEqual(AcarsDecoder.plainLabel(nil, text: ""), "Link frame")
        XCTAssertEqual(AcarsDecoder.plainLabel("ZZ", text: ""), "Message")
    }

    func testDirectionAndLink() {
        func dir(_ link: String? = nil, from: String? = nil, to: String? = nil, block: String? = nil) -> AcarsDirection? {
            AcarsDecoder.direction(link: link, fromHex: from, toHex: to, blockID: block, aircraftHex: "a03b6d")
        }
        XCTAssertEqual(dir("uplink", from: "C1", to: "8963E2"), .uplink)
        XCTAssertEqual(dir("downlink"), .downlink)
        XCTAssertEqual(dir(from: "A03B6D", to: "11351A"), .downlink)
        XCTAssertEqual(dir(from: "11955A", to: "a03b6d"), .uplink)
        XCTAssertEqual(dir(to: "11213a", block: "6"), .downlink, "ARINC 618: downlink blocks are digits")
        XCTAssertEqual(dir(to: "11213a", block: "T"), .uplink)
        XCTAssertNil(dir())
        XCTAssertEqual(AcarsDecoder.linkName("acars"), "ACARS")
        XCTAssertEqual(AcarsDecoder.linkName("vdl"), "VDL2")
        XCTAssertEqual(AcarsDecoder.linkName("hfdl"), "HFDL")
        XCTAssertEqual(AcarsDecoder.linkName("aero-acars"), "Satcom")
    }

    // MARK: OOOI

    func testOOOITimeFromReport() throws {
        // A real QP (OUT) report: origin, destination, then the event time.
        let m = try message(label: "QP", text: "KLAXKLAS0334 127     ,,", at: "2026-11-27T03:34:07.000Z")
        XCTAssertEqual(m.event, OOOIReport(kind: .out, time: Self.date("2026-11-27T03:34:00.000Z")))
        XCTAssertEqual(m.fields.map(\.value), ["03:34Z", "KLAX → KLAS"])
        XCTAssertFalse(m.isNoise)
    }

    func testOOOIAcrossMidnightAndWithoutTime() {
        let sent = Self.date("2026-11-27T00:02:00.000Z")
        let late = AcarsDecoder.oooi(label: "QB", text: "KJFKKLAX2355", sent: sent)
        XCTAssertEqual(late?.kind, .off)
        XCTAssertEqual(late?.time, Self.date("2026-11-26T23:55:00.000Z"))
        // No time in the text: the report's own time stands in.
        XCTAssertEqual(AcarsDecoder.oooi(label: "QD", text: "", sent: sent)?.time, sent)
        XCTAssertEqual(AcarsDecoder.oooi(label: "QD", text: "", sent: sent)?.kind, .arrivedIn)
        XCTAssertNil(AcarsDecoder.oooi(label: "H1", text: "KLAXKLAS0334", sent: sent))
    }

    func testFlightCollectsEarliestOOOITimes() throws {
        let json = #"""
        {"id":1,"messages":[
         {"id":3,"timestamp":"2026-11-27T03:52:00.000Z","label":"QB","text":"KLAXKLAS0351"},
         {"id":2,"timestamp":"2026-11-27T03:35:00.000Z","label":"QA","text":"KLAXKLAS0334"},
         {"id":1,"timestamp":"2026-11-27T03:34:30.000Z","label":"QP","text":"KLAXKLAS0333"}]}
        """#
        let f = AcarsFlight(try XCTUnwrap(AirframesAPI.decode(AirframesAPI.Flight.self, from: Data(json.utf8))), aircraftHex: "abc123")
        XCTAssertEqual(f.times[.out], Self.date("2026-11-27T03:33:00.000Z"))
        XCTAssertEqual(f.times[.off], Self.date("2026-11-27T03:51:00.000Z"))
        XCTAssertNil(f.times[.on])
    }

    // MARK: Route fixes and positions

    func testWaypointsFromWindRequest() {
        // Real BA57K request, reassembled by Airframes.io: ends with "/DQ410/…".
        let full = "REQPWI/TS221328,261126/WQ410.390.360.340:PUMAL.XEPLA.BCN.GARBI.LARPA.TOLSO.LISAS/DQ410/WRFAOR.FALE8E78"
        XCTAssertEqual(AcarsDecoder.waypoints(in: full), ["PUMAL", "XEPLA", "BCN", "GARBI", "LARPA", "TOLSO", "LISAS"])
        XCTAssertEqual(AcarsDecoder.windLevels(in: full), ["FL410", "FL390", "FL360", "FL340"])
        // A single block cut mid-route: the last name may be truncated, so it's dropped.
        XCTAssertEqual(AcarsDecoder.waypoints(in: "REQPWI/TS221328,261126/WQ410:PUMAL.XEPLA.AMR"), ["PUMAL", "XEPLA"])
        XCTAssertEqual(AcarsDecoder.waypoints(in: "REQPWI/TS221328,261126/WQ410:PUMAL.XEPLA."), ["PUMAL", "XEPLA"])
        // Coordinates aren't fixes.
        XCTAssertEqual(AcarsDecoder.waypoints(in: "REQPWI/WQ390.360.340.320:ACK.WHALE.NANSO.RAFIN.4550N/DQ390"),
                       ["ACK", "WHALE", "NANSO", "RAFIN"])
    }

    func testWaypointsFromPositionReport() {
        let core = AcarsDecoder.core("#M1BPOSN47144W122283,BREVE,033304,100,NETTZ,033431,KWEST,M8,253042,106,292,281K,242K,730E64")
        XCTAssertEqual(AcarsDecoder.waypoints(in: core), ["BREVE", "NETTZ", "KWEST"])
        // Reported as coordinates: nothing to name.
        XCTAssertEqual(AcarsDecoder.waypoints(in: "POSN47462E000381,N47481E000376,221337,350,N47233E000445,221612,N47000E000509,M54,35373"), [])
    }

    func testFlightRouteFixesInRouteOrder() throws {
        let json = #"""
        {"id":1,"messages":[
         {"id":2,"timestamp":"2026-11-27T03:40:00.000Z","label":"H1","text":"POSN47144W122283,NETTZ,034004,100,KWEST,034431,ZEBRA,M8,1"},
         {"id":1,"timestamp":"2026-11-27T03:33:00.000Z","label":"H1","text":"POSN47144W122283,BREVE,033304,100,NETTZ,033431,KWEST,M8,2"}]}
        """#
        let f = AcarsFlight(try XCTUnwrap(AirframesAPI.decode(AirframesAPI.Flight.self, from: Data(json.utf8))), aircraftHex: "abc123")
        XCTAssertEqual(f.waypoints, ["BREVE", "NETTZ", "KWEST", "ZEBRA"])
    }

    func testPositionsInUnambiguousFormats() throws {
        func pos(_ s: String) -> GeoPoint? { AcarsDecoder.position(in: s) }
        let jeju = try XCTUnwrap(pos("N 41.193/E141.675 /UTC 0329"))
        XCTAssertEqual(jeju.lat, 41.193, accuracy: 1e-9)
        XCTAssertEqual(jeju.lon, 141.675, accuracy: 1e-9)
        let florida = try XCTUnwrap(pos("POSN 30.627W 81.196, 106,032930,33993,24975, 115,-46,035554,KMCO"))
        XCTAssertEqual(florida.lon, -81.196, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(pos("CAS 259,LAT N 58.253,LON E 20.112,ALT 31998")).lon, 20.112, accuracy: 1e-9)
        let minutes = try XCTUnwrap(pos("N5415.2,E01202.9,270319, 36006"))
        XCTAssertEqual(minutes.lat, 54 + 15.2 / 60, accuracy: 1e-9)
        XCTAssertEqual(minutes.lon, 12 + 2.9 / 60, accuracy: 1e-9)
        let suffix = try XCTUnwrap(pos("AGFSR AC0788/26/27/LAXYYZ/0333Z/456/4251.5N 8745.7W/370"))
        XCTAssertEqual(suffix.lat, 42 + 51.5 / 60, accuracy: 1e-9)
        XCTAssertEqual(suffix.lon, -(87 + 45.7 / 60), accuracy: 1e-9)
        // Packed digits read as decimal degrees by some airlines and as minutes by others: skipped.
        XCTAssertNil(pos("POSN47462E000381,N47481E000376,221337,350"))
        XCTAssertNil(pos("N 400039W 780018,-------,033348,32356"))
        XCTAssertEqual(AcarsDecoder.format(florida), "30.627° N, 81.196° W")
    }

    // MARK: Polling policy and budget

    func testListIsReadOftenWhileSearchingAndRarelyOnceFound() {
        let t0 = now
        var c = AcarsCursor()
        XCTAssertTrue(AcarsService.isListDue(c, now: t0))
        c.listCheckedAt = t0
        XCTAssertFalse(AcarsService.isListDue(c, now: t0.addingTimeInterval(60)))
        XCTAssertTrue(AcarsService.isListDue(c, now: t0.addingTimeInterval(120)))
        c.flightID = 5559112489
        XCTAssertFalse(AcarsService.isListDue(c, now: t0.addingTimeInterval(300)))
        XCTAssertTrue(AcarsService.isListDue(c, now: t0.addingTimeInterval(600)))
    }

    func testAirframeCacheLifetimes() {
        XCTAssertTrue(AcarsService.isFresh(.init(id: 12696, at: now), now: now.addingTimeInterval(23 * 3_600)))
        XCTAssertFalse(AcarsService.isFresh(.init(id: 12696, at: now), now: now.addingTimeInterval(25 * 3_600)))
        XCTAssertFalse(AcarsService.isFresh(.init(id: nil, at: now), now: now.addingTimeInterval(7 * 3_600)))
        let pruned = AcarsService.pruned(["a": .init(id: 1, at: now), "b": .init(id: nil, at: now.addingTimeInterval(-86_400))], now: now)
        XCTAssertEqual(Array(pruned.keys), ["a"])
    }

    func testAirframesRequestsAreCountedAndResetTimeIsUnixTime() {
        XCTAssertEqual(ApiService(host: "api.airframes.io"), .airframes)
        let t = Date(timeIntervalSince1970: 1_795_750_130)
        let pause = ApiBudget.pauseInterval(service: .airframes, status: 429,
                                            headers: ["x-ratelimit-reset": "1795750170"], now: t)
        XCTAssertEqual(try XCTUnwrap(pause), 40, accuracy: 1e-6)
        XCTAssertEqual(ApiBudget.pauseInterval(service: .airframes, status: 429, headers: ["Retry-After": "12"], now: t), 12)
        XCTAssertNil(ApiBudget.pauseInterval(service: .airframes, status: 200,
                                             headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1795750170"], now: t))
    }

    // MARK: Route hint

    private func liveFlight(lat: Double, lon: Double, track: Double) -> Flight {
        let json = """
        {"hex":"a03b6d","flight":"DAL1343","t":"BCS1","alt_baro":36000,"gs":450,"track":\(track),
         "lat":\(lat),"lon":\(lon),"dst":10,"dir":90,"baro_rate":0}
        """
        return Flight(adsb: try! JSONDecoder().decode(ADSBAircraft.self, from: Data(json.utf8)))!
    }

    func testAcarsRouteIsALowerPriorityHint() throws {
        let hint = try XCTUnwrap(try flight().route(scheduled: nil))
        XCTAssertEqual("\(hint.from.code)-\(hint.to.code)", "AUS-SLC")
        // Over New Mexico, heading for Salt Lake City.
        let enRoute = liveFlight(lat: 35.0, lon: -105.0, track: 320)
        let used = RouteResolver.resolve(scheduled: nil, flight: enRoute, departedFrom: nil, hint: hint)
        XCTAssertEqual(used.route, hint)
        XCTAssertEqual(used.note, "Route reported by the aircraft over ACARS.")
        // A plausible scheduled route wins.
        let lax = try XCTUnwrap(AirportDB.airport(code: "LAX")), las = try XCTUnwrap(AirportDB.airport(code: "KLAS"))
        let scheduled = RouteInfo(airline: nil, flightNo: "DL1343", from: try XCTUnwrap(AirportDB.airport(code: "ELP")), to: las)
        XCTAssertEqual(RouteResolver.resolve(scheduled: scheduled, flight: liveFlight(lat: 33.0, lon: -110.0, track: 310),
                                             departedFrom: nil, hint: hint).route, scheduled)
        // Not where the aircraft is, or contradicting the recorded departure: ignored.
        XCTAssertNil(RouteResolver.resolve(scheduled: nil, flight: liveFlight(lat: 27.0, lon: -81.0, track: 0),
                                           departedFrom: nil, hint: hint).route)
        XCTAssertNil(RouteResolver.resolve(scheduled: nil, flight: enRoute, departedFrom: lax, hint: hint).route)
    }
}
