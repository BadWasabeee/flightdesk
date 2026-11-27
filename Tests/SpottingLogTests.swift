import XCTest

final class SpottingLogTests: XCTestCase {

    private func flight(_ hex: String, callsign: String = "", reg: String = "N1", type: String = "B738",
                        alt: Int = 10_000, dst: Double = 10) -> Flight {
        let json = """
        {"hex":"\(hex)","flight":"\(callsign)","r":"\(reg)","t":"\(type)","alt_baro":\(alt),"gs":450,
         "track":90,"lat":36.0,"lon":-88.2,"dst":\(dst),"dir":90}
        """
        return Flight(adsb: try! JSONDecoder().decode(ADSBAircraft.self, from: Data(json.utf8)))!
    }

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let ord = Airport(code: "ORD", city: "Chicago", lat: 41.98, lon: -87.9)
    private let den = Airport(code: "DEN", city: "Denver", lat: 39.86, lon: -104.67)

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // MARK: Sightings (the 30-minute rule)

    func testFirstObservationCreatesEntry() {
        var log = SpottingLog()
        let change = log.record([flight("abc123", callsign: "UAL12", reg: "N12UA", dst: 8)], at: t0)
        XCTAssertEqual(change.added, ["abc123"])
        let e = try! XCTUnwrap(log["abc123"])
        XCTAssertEqual(e.sightings, 1)
        XCTAssertEqual(e.firstSeen, t0)
        XCTAssertEqual(e.lastSeen, t0)
        XCTAssertEqual(e.registration, "N12UA")
        XCTAssertEqual(e.callsigns, ["UAL12"])
        XCTAssertEqual(e.airlineICAO, "UAL")
    }

    func testObservationsWithin30MinutesAreOneSighting() {
        var log = SpottingLog()
        log.record([flight("abc123")], at: t0)
        // Every 20 minutes for an hour: never a 30-minute gap.
        for m in [20, 40, 60] { log.record([flight("abc123")], at: t0 + Double(m) * 60) }
        XCTAssertEqual(log["abc123"]?.sightings, 1)
        XCTAssertEqual(log["abc123"]?.lastSeen, t0 + 3600)
    }

    func testGapOfExactly30MinutesIsNotANewSighting() {
        var log = SpottingLog()
        log.record([flight("abc123")], at: t0)
        let change = log.record([flight("abc123")], at: t0 + 30 * 60)
        XCTAssertFalse(change.newSighting)
        XCTAssertEqual(log["abc123"]?.sightings, 1)
    }

    func testGapOver30MinutesIsANewSighting() {
        var log = SpottingLog()
        log.record([flight("abc123")], at: t0)
        let change = log.record([flight("abc123")], at: t0 + 30 * 60 + 1)
        XCTAssertTrue(change.newSighting)
        XCTAssertTrue(change.added.isEmpty)
        XCTAssertEqual(log["abc123"]?.sightings, 2)
        XCTAssertEqual(log["abc123"]?.firstSeen, t0)
    }

    // MARK: Dedupe

    func testDedupesByHexCaseInsensitivelyAndWithinABatch() {
        var log = SpottingLog()
        log.record([flight("ABC123"), flight("abc123")], at: t0)
        log.record([flight("abc123")], at: t0 + 60)
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log["ABC123"]?.sightings, 1)
    }

    func testSkipsNonICAOAddresses() {
        var log = SpottingLog()
        log.record([flight("~abc123"), flight("xyz")], at: t0)
        XCTAssertTrue(log.isEmpty)
    }

    func testKeepsDetailsWhenLaterObservationsOmitThem() {
        var log = SpottingLog()
        var f = flight("abc123", callsign: "UAL12", reg: "N12UA", type: "B739")
        f.route = RouteInfo(airline: "United Airlines", flightNo: "UA12", airlineCode: "UA", from: ord, to: den)
        log.record([f], at: t0)
        // The feed falls back to the hex for a missing registration; no type, no callsign.
        log.record([flight("abc123", callsign: "", reg: "ABC123", type: "")], at: t0 + 60)
        let e = try! XCTUnwrap(log["abc123"])
        XCTAssertEqual(e.registration, "N12UA")
        XCTAssertEqual(e.typeCode, "B739")
        XCTAssertEqual(e.operatorName, "United Airlines")
        XCTAssertEqual(e.airlineIATA, "UA")
        XCTAssertEqual(e.routes, ["ORD-DEN"])
        XCTAssertEqual(e.callsigns, ["UAL12"])
    }

    func testHexStandsInForMissingRegistration() {
        var log = SpottingLog()
        log.record([flight("abc123", reg: "ABC123")], at: t0)
        XCTAssertEqual(log["abc123"]?.registration, "")
        XCTAssertEqual(log["abc123"]?.displayName, "ABC123")
    }

    func testCallsignsAndRoutesAreDedupedAndCapped() {
        var log = SpottingLog()
        for i in 0..<(SpottingLog.callsignLimit + 3) { log.record([flight("abc123", callsign: "UAL\(i)")], at: t0 + Double(i)) }
        log.record([flight("abc123", callsign: "UAL3")], at: t0 + 100)   // seen again: moves to the end
        let calls = try! XCTUnwrap(log["abc123"]?.callsigns)
        XCTAssertEqual(calls.count, SpottingLog.callsignLimit)
        XCTAssertEqual(calls.last, "UAL3")
        XCTAssertEqual(Set(calls).count, calls.count)
        XCTAssertFalse(calls.contains("UAL0"))
    }

    // MARK: Closest pass and altitude

    func testClosestPassOnlyMovesCloser() {
        var log = SpottingLog()
        log.record([flight("abc123", alt: 5000, dst: 12)], at: t0)
        log.record([flight("abc123", alt: 9000, dst: 3.4)], at: t0 + 60)
        log.record([flight("abc123", alt: 7000, dst: 6)], at: t0 + 120)
        let e = try! XCTUnwrap(log["abc123"])
        XCTAssertEqual(e.closestNM, 3.4, accuracy: 0.001)
        XCTAssertEqual(e.closestAt, t0 + 60)
        XCTAssertEqual(e.maxAltitude, 9000)
    }

    // MARK: Stats and filters

    func testStats() {
        var log = SpottingLog()
        log.record([flight("a00001", callsign: "UAL1", type: "B738"),
                    flight("a00002", callsign: "UAL2", type: "B738"),
                    flight("a00003", callsign: "DAL3", type: "A388")], at: t0 - 3 * 86_400)
        log.record([flight("a00004", callsign: "N123AB", type: "C172"),
                    flight("a00001", callsign: "UAL1", type: "B738")], at: t0)
        let s = log.stats(now: t0, calendar: utc)
        XCTAssertEqual(s.aircraft, 4)
        XCTAssertEqual(s.types, 3)
        XCTAssertEqual(s.airlines, 2)          // UAL, DAL (N123AB isn't an airline callsign)
        XCTAssertEqual(s.today, 2)
        XCTAssertEqual(s.rarestTypes, ["C172", "A388"])   // seen once, most recent first
    }

    func testFiltersAndSort() {
        var log = SpottingLog(entries: [])
        log.record([flight("a00001", reg: "N1", type: "B77W", dst: 9)], at: t0 - 10 * 86_400)
        log.record([flight("a00002", reg: "N2", type: "B738", dst: 2)], at: t0 - 3600)
        log.record([flight("a00003", reg: "N3", type: "C17", dst: 5)], at: t0)
        let ids = { (f: LogFilter, s: LogSort) in log.entries(matching: f, sort: s, now: self.t0, calendar: self.utc) { $0 == "a00003" ? "Mil" : nil }.map(\.hex) }
        XCTAssertEqual(ids(LogFilter(), .lastSeen), ["a00003", "a00002", "a00001"])
        XCTAssertEqual(ids(LogFilter(), .closest), ["a00002", "a00003", "a00001"])
        XCTAssertEqual(ids(LogFilter(period: .week), .lastSeen).contains("a00001"), false)
        XCTAssertEqual(ids(LogFilter(wideBodiesOnly: true), .registration), ["a00001", "a00003"])
        XCTAssertEqual(ids(LogFilter(militaryOnly: true), .lastSeen), ["a00003"])
        XCTAssertEqual(ids(LogFilter(query: "b73"), .lastSeen), ["a00002"])
    }

    func testCompactionKeepsMostRecentlySeen() {
        var log = SpottingLog()
        log.record([flight("a00001")], at: t0)
        log.record([flight("a00002")], at: t0 + 10)
        log.record([flight("a00003")], at: t0 + 20)
        log.compact(to: 2)
        XCTAssertEqual(Set(log.entries.keys), ["a00002", "a00003"])
    }

    // MARK: Persistence

    func testPersistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpottingLogTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nested/spotting-log.json")
        var log = SpottingLog()
        var f = flight("abc123", callsign: "UAL12", reg: "N12UA", dst: 4.25)
        f.route = RouteInfo(airline: "United Airlines", flightNo: "UA12", airlineCode: "UA", from: ord, to: den)
        log.record([f, flight("def456", type: "A388")], at: t0, group: { $0 == "def456" ? "Mil" : nil })
        log.record([f], at: t0 + 3600)
        try log.write(to: url)
        let back = SpottingLog.load(from: url)
        XCTAssertEqual(back, log)
        XCTAssertEqual(back["abc123"]?.sightings, 2)
        XCTAssertEqual(back["def456"]?.alertGroup, "Mil")
    }

    func testMissingFileLoadsEmptyAndCorruptFileIsSetAside() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpottingLogTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("spotting-log.json")
        XCTAssertTrue(SpottingLog.load(from: url).isEmpty)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(SpottingLog.load(from: url).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
    }

    // MARK: CSV

    func testCSVFieldEscaping() {
        XCTAssertEqual(SpottingLog.csvField("United Airlines"), "United Airlines")
        XCTAssertEqual(SpottingLog.csvField("Smith, John"), "\"Smith, John\"")
        XCTAssertEqual(SpottingLog.csvField("The \"Spirit\""), "\"The \"\"Spirit\"\"\"")
        XCTAssertEqual(SpottingLog.csvField("line\nbreak"), "\"line\nbreak\"")
        XCTAssertEqual(SpottingLog.csvField("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"")
        XCTAssertEqual(SpottingLog.csvField("+1"), "'+1")
        XCTAssertEqual(SpottingLog.csvField(""), "")
    }

    func testCSVDocument() {
        var log = SpottingLog()
        var f = flight("abc123", callsign: "UAL12", reg: "N12UA", alt: 35_000, dst: 4.25)
        f.route = RouteInfo(airline: "United, Inc.", flightNo: "UA12", airlineCode: "UA", from: ord, to: den)
        log.record([f], at: t0)
        let csv = SpottingLog.csv(Array(log.entries.values))
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.count, 3)                      // header, one row, trailing empty
        XCTAssertEqual(lines[0], SpottingLog.csvHeader.joined(separator: ","))
        XCTAssertTrue(lines[1].hasPrefix("ABC123,N12UA,B738,\"United, Inc.\",2026-"))
        XCTAssertTrue(lines[1].hasSuffix(",1,4.2,\(ISO8601DateFormatter().string(from: t0)),35000,UAL12,ORD-DEN")
                      || lines[1].hasSuffix(",1,4.3,\(ISO8601DateFormatter().string(from: t0)),35000,UAL12,ORD-DEN"))
    }
}
