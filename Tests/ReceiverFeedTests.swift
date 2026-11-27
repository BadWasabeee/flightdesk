import XCTest

final class ReceiverFeedTests: XCTestCase {

    /// Observer near Heathrow.
    private let home = GeoPoint(lat: 51.47, lon: -0.45)

    /// A local `aircraft.json` as served by readsb/dump1090-fa: no `dst`/`dir`, mostly no `r`/`t`.
    private let sample = """
    {"now": 1764150000.4, "messages": 123456, "aircraft": [
      {"hex":"4ca7b4","flight":"RYR55AB ","alt_baro":36000,"gs":440.1,"track":95.2,"lat":51.97,"lon":-0.45,
       "seen_pos":1.2,"squawk":"2312","category":"A3","baro_rate":-64,"messages":512,"seen":0.4,"rssi":-21.5},
      {"hex":"406B2A","flight":"BAW12   ","r":"G-XWBA","t":"A35K","alt_baro":4200,"gs":180,"track":270,
       "lat":51.47,"lon":-0.30,"seen_pos":0.3,"geom_rate":-768},
      {"hex":"400f01","alt_baro":"ground","gs":12,"lat":51.471,"lon":-0.46,"seen_pos":0.5},
      {"hex":"3c6444","flight":"DLH4AB","alt_baro":38000,"lat":51.60,"lon":-0.40,"seen_pos":75},
      {"hex":"a1b2c3","alt_baro":12000,"messages":30,"seen":2.0},
      {"hex":"~2a0001","alt_baro":2500,"lat":51.40,"lon":-0.45,"seen_pos":3,"type":"tisb_icao"},
      {"hex":12345,"alt_baro":"oops"},
      {"hex":"777777","altitude":9000,"speed":250,"vert_rate":1024,"lat":53.5,"lon":-0.45,"seen_pos":2}
    ]}
    """

    private func decode(_ json: String) throws -> ReceiverAircraftFile {
        try JSONDecoder().decode(ReceiverAircraftFile.self, from: Data(json.utf8))
    }

    // MARK: Decoding

    func testDecodesLocalAircraftJSONWithoutDistanceOrRegistration() throws {
        let file = try decode(sample)
        XCTAssertEqual(file.messages, 123456)
        XCTAssertEqual(file.aircraft.count, 7, "the malformed entry is skipped, not fatal")

        let f = try XCTUnwrap(Flight(receiver: file.aircraft[0], observer: home))
        XCTAssertEqual(f.id, "4ca7b4")
        XCTAssertEqual(f.callsign, "RYR55AB")
        XCTAssertEqual(f.reg, "4CA7B4", "falls back to the hex like the internet feeds")
        XCTAssertEqual(f.typeCode, "")
        XCTAssertEqual(f.altitude, 36000)
        XCTAssertEqual(f.verticalRate, -64)
        XCTAssertEqual(f.speed, 440.1, accuracy: 0.01)
        XCTAssertEqual(f.distance, 30, accuracy: 0.1, "0.5° due north ≈ 30 nm")
        XCTAssertEqual(f.bearing, 0, accuracy: 0.5)

        let baw = try XCTUnwrap(Flight(receiver: file.aircraft[1], observer: home))
        XCTAssertEqual(baw.id, "406b2a", "ids are normalised to lowercase")
        XCTAssertEqual(baw.reg, "G-XWBA")
        XCTAssertEqual(baw.typeCode, "A35K")
        XCTAssertEqual(baw.verticalRate, -768)
        XCTAssertEqual(baw.bearing, 90, accuracy: 0.5)
    }

    func testLegacyDump1090FieldNames() throws {
        let f = try XCTUnwrap(Flight(receiver: decode(sample).aircraft[6], observer: home))
        XCTAssertEqual(f.altitude, 9000)
        XCTAssertEqual(f.speed, 250)
        XCTAssertEqual(f.verticalRate, 1024)
    }

    func testSkipsGroundTrafficMissingPositionAndStalePositions() throws {
        let a = try decode(sample).aircraft
        XCTAssertNil(Flight(receiver: a[2], observer: home), "ground traffic")
        XCTAssertNil(Flight(receiver: a[3], observer: home), "seen_pos 75 s is stale")
        XCTAssertNil(Flight(receiver: a[4], observer: home), "no position")
        XCTAssertNotNil(Flight(receiver: a[2], observer: home, allowGround: true))
        XCTAssertNotNil(Flight(receiver: a[3], observer: home, maxPositionAge: 90))
    }

    func testMissingAircraftKeyIsNotAReceiverFile() {
        XCTAssertThrowsError(try decode(#"{"now": 1, "messages": 2}"#))
        XCTAssertThrowsError(try decode("<html>tar1090</html>"))
        XCTAssertEqual(try decode(#"{"aircraft": []}"#).aircraft.count, 0)
    }

    // MARK: Filtering

    func testFiltersToRadiusAndSortsNearestFirst() throws {
        let file = try decode(sample)
        let list = ReceiverFeed.flights(in: file, observer: home, radiusNM: 25)
        XCTAssertEqual(list.map(\.id), ["~2a0001", "406b2a"], "RYR at 30 nm and 777777 at 120 nm are outside")
        XCTAssertEqual(list[0].distance, 4.2, accuracy: 0.1)
        XCTAssertEqual(list[0].bearing, 180, accuracy: 0.5)

        let wide = ReceiverFeed.flights(in: file, observer: home, radiusNM: 50)
        XCTAssertEqual(wide.map(\.id), ["~2a0001", "406b2a", "4ca7b4"])
        XCTAssertEqual(wide.map(\.distance), wide.map(\.distance).sorted())
    }

    // MARK: Single aircraft

    func testReportFindsHexIncludingGroundTraffic() throws {
        let file = try decode(sample)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let r = try XCTUnwrap(ReceiverFeed.report(hex: "4CA7B4", in: file, observer: home, now: now))
        XCTAssertEqual(r.squawk, "2312")
        XCTAssertFalse(r.onGround)
        XCTAssertEqual(r.positionTime.timeIntervalSince(now), -1.2, accuracy: 0.001)
        XCTAssertEqual(r.flight.distance, 30, accuracy: 0.1)

        let ground = try XCTUnwrap(ReceiverFeed.report(hex: "400f01", in: file, observer: nil))
        XCTAssertTrue(ground.onGround)
        XCTAssertEqual(ground.flight.distance, 0)

        XCTAssertNil(ReceiverFeed.report(hex: "3c6444", in: file, observer: home), "stale position")
        XCTAssertNil(ReceiverFeed.report(hex: "abcdef", in: file, observer: home), "not tracked")
    }

    // MARK: URL candidates

    private func candidates(_ s: String) -> [String] { ReceiverFeed.candidateURLs(for: s).map(\.absoluteString) }

    func testCandidatesForTar1090BaseWithoutScheme() {
        XCTAssertEqual(candidates("raspberrypi.local/tar1090"), [
            "http://raspberrypi.local/tar1090/data/aircraft.json",
            "http://raspberrypi.local/tar1090/aircraft.json",
            "http://raspberrypi.local/tar1090/tar1090/data/aircraft.json",
            "http://raspberrypi.local/tar1090/skyaware/data/aircraft.json",
            "http://raspberrypi.local/tar1090/dump1090-fa/data/aircraft.json",
            "http://raspberrypi.local/tar1090/dump1090/data/aircraft.json",
        ])
    }

    func testCandidatesTrimSlashesAndKeepPort() {
        let c = candidates("  http://192.168.1.50:8080///  ")
        XCTAssertEqual(c.first, "http://192.168.1.50:8080/data/aircraft.json")
        XCTAssertTrue(c.contains("http://192.168.1.50:8080/skyaware/data/aircraft.json"))
        XCTAssertEqual(c.count, ReceiverFeed.knownPaths.count)
        XCTAssertEqual(candidates("HTTP://piaware.local/skyaware/").first, "http://piaware.local/skyaware/data/aircraft.json")
    }

    func testCandidateAlreadyPointingAtJSONIsUsedAsIs() {
        XCTAssertEqual(candidates("http://piaware.local/skyaware/data/aircraft.json"),
                       ["http://piaware.local/skyaware/data/aircraft.json"])
        XCTAssertEqual(candidates("pi.local:8504/aircraft.json?x=1"), ["http://pi.local:8504/aircraft.json"])
    }

    func testCandidatesIgnorePageNameQueryAndFragment() {
        XCTAssertEqual(candidates("http://pi.local/tar1090/index.html?icao=4ca7b4#map").first,
                       "http://pi.local/tar1090/data/aircraft.json")
        XCTAssertEqual(candidates("http://pi.local/data/").first, "http://pi.local/data/aircraft.json",
                       "a base ending in /data tries its aircraft.json first")
        XCTAssertEqual(candidates("https://pi.example.org/tar1090").first, "https://pi.example.org/tar1090/data/aircraft.json")
    }

    func testInvalidInputsHaveNoCandidates() {
        XCTAssertEqual(candidates(""), [])
        XCTAssertEqual(candidates("   "), [])
        XCTAssertEqual(candidates("ftp://pi.local"), [])
        XCTAssertEqual(candidates("http://"), [])
        XCTAssertEqual(candidates("not a url"), [])
    }

    // MARK: Settings & routing

    func testSettingsDecodeLeniently() throws {
        let s = try JSONDecoder().decode(ReceiverSettings.self, from: Data(#"{"enabled":true,"url":"pi.local"}"#.utf8))
        XCTAssertEqual(s, ReceiverSettings(enabled: true, url: "pi.local", useAsOnlySource: false))
        XCTAssertEqual(try JSONDecoder().decode(ReceiverSettings.self, from: Data("{}".utf8)), ReceiverSettings())
    }

    func testActivityAndCacheTag() {
        XCTAssertFalse(ReceiverSettings(enabled: true, url: "  ").isActive)
        XCTAssertFalse(ReceiverSettings(enabled: false, url: "pi.local").isActive)
        XCTAssertEqual(ReceiverSettings().cacheTag, "")
        XCTAssertEqual(ReceiverSettings(enabled: true, url: "pi.local").cacheTag, "|rx")
        XCTAssertEqual(ReceiverSettings(enabled: true, url: "pi.local", useAsOnlySource: true).cacheTag, "|rx-only")
    }

    func testRouteOrder() async throws {
        await FeedHealth.shared.receiverSucceeded()
        var calls: [String] = []
        func run(_ s: ReceiverSettings, local: Int?, internet: Int?) async throws -> Int? {
            try await ReceiverFeed.route(s, local: { calls.append("local"); return local },
                                         internet: { calls.append("internet"); return internet })
        }
        let on = ReceiverSettings(enabled: true, url: "pi.local")

        var v = try await run(ReceiverSettings(), local: 1, internet: 2)
        XCTAssertEqual(v, 2); XCTAssertEqual(calls, ["internet"]); calls = []

        v = try await run(ReceiverSettings(enabled: true, url: "pi.local", useAsOnlySource: true), local: nil, internet: 2)
        XCTAssertNil(v); XCTAssertEqual(calls, ["local"]); calls = []

        v = try await run(on, local: 1, internet: 2)
        XCTAssertEqual(v, 1); XCTAssertEqual(calls, ["local"]); calls = []

        v = try await run(on, local: nil, internet: 2)
        XCTAssertEqual(v, 2); XCTAssertEqual(calls, ["local", "internet"]); calls = []

        await FeedHealth.shared.receiverFailed(for: 60)
        v = try await run(on, local: 1, internet: 2)
        XCTAssertEqual(v, 2); XCTAssertEqual(calls, ["internet"]); calls = []

        let fromLocal: Int? = try await ReceiverFeed.route(on, local: { 1 }, internet: { throw URLError(.timedOut) })
        XCTAssertEqual(fromLocal, 1, "a benched receiver is still tried when the internet fails")
        await FeedHealth.shared.receiverSucceeded()
    }

    func testSoftwareNameHeuristics() {
        XCTAssertEqual(ReceiverFeed.softwareName(version: "wiedehopf git: 1a2b3c", path: "/data/aircraft.json"), "readsb")
        XCTAssertEqual(ReceiverFeed.softwareName(version: "9.0", path: "/skyaware/data/aircraft.json"), "dump1090-fa")
        XCTAssertEqual(ReceiverFeed.softwareName(version: "", path: "/tar1090/data/aircraft.json"), "tar1090")
        XCTAssertNil(ReceiverFeed.softwareName(version: "", path: "/data/aircraft.json"))
    }

    func testErrorMessagesAreHelpful() {
        XCTAssertTrue(ReceiverFeed.describe(URLError(.cannotFindHost), base: "pi.local/tar1090").contains("pi.local"))
        XCTAssertTrue(ReceiverFeed.describe(ReceiverError.noAircraftData(host: "pi.local"), base: "pi.local").contains("aircraft.json"))
    }

    // MARK: Live receiver (opt-in)

    /// Discovery against a real or simulated receiver. Set `FLIGHTDESK_RECEIVER_URL` (pass it to
    /// xcodebuild as `TEST_RUNNER_FLIGHTDESK_RECEIVER_URL`) to run.
    func testDiscoveryAgainstLiveReceiver() async throws {
        guard let base = ProcessInfo.processInfo.environment["FLIGHTDESK_RECEIVER_URL"], !base.isEmpty else {
            throw XCTSkip("FLIGHTDESK_RECEIVER_URL not set")
        }
        let found = try await ReceiverFeed.discover(base)
        XCTAssertTrue(found.url.path.hasSuffix("aircraft.json"))
        XCTAssertFalse(found.file.aircraft.isEmpty)
        let result = await ReceiverFeed.test(base, observer: home, radiusNM: 25)
        XCTAssertTrue(result.ok, result.message)
        print("Receiver test: \(result.message) — \(result.detail ?? "")")
    }
}
