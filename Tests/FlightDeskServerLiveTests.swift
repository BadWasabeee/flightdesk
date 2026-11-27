import XCTest

/// Checks the app's decoders against a real FlightDesk server. Skipped unless both
/// `FLIGHTDESK_SERVER_URL` and `FLIGHTDESK_SERVER_TOKEN` are set in the test environment (with
/// xcodebuild, export them prefixed with `TEST_RUNNER_`). Nothing here is ever committed with a
/// value: the server and token come only from the environment.
///
/// Side effect on the server: one `POST /v1/watch` for an aircraft already in its area.
final class FlightDeskServerLiveTests: XCTestCase {
    private var saved: FlightDeskServer!

    override func setUp() async throws {
        try await super.setUp()
        saved = FlightDeskServer.shared
    }

    override func tearDown() async throws {
        FlightDeskServer.shared = saved
        try await super.tearDown()
    }

    private func liveServer() throws -> (FlightDeskServer, String, String) {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["FLIGHTDESK_SERVER_URL"], !url.isEmpty,
              let token = env["FLIGHTDESK_SERVER_TOKEN"], !token.isEmpty else {
            throw XCTSkip("Set FLIGHTDESK_SERVER_URL and FLIGHTDESK_SERVER_TOKEN to run against a live server")
        }
        let settings = ServerSettings(enabled: true, url: url)
        XCTAssertTrue(settings.isActive, "the URL must pass validation")
        let server = FlightDeskServer(session: FlightDeskServer.makeSession(timeout: 10, countRequests: false),
                                      settings: { settings }, tokens: MemorySecretStore(token), timeout: 10)
        return (server, url, token)
    }

    func testDecodersAcceptLiveResponses() async throws {
        let (server, url, token) = try liveServer()
        FlightDeskServer.shared = server

        // Settings › Test Connection.
        let test = await FlightDeskServer.test(url: url, token: token)
        XCTAssertTrue(test.ok, test.message)
        print("LIVE test connection: \(test.message) | \(test.detail ?? "")")

        // The area centre, from /v1/stats.
        struct Stats: Decodable { struct Poller: Decodable { let centerLat: Double; let centerLon: Double }; let poller: Poller }
        let statsResponse = await server.get(["v1", "stats"])
        let statsData = try XCTUnwrap(statsResponse?.data)
        let centre = try JSONDecoder().decode(Stats.self, from: statsData).poller

        // Positions: through the app's own source chain, as the panel and widgets fetch them.
        let (flights, source) = try await FlightService.nearbyFromSources(
            lat: centre.centerLat, lon: centre.centerLon, radiusNM: 50, receiver: ReceiverSettings(), server: server,
            local: { [] }, feeds: { XCTFail("the server should answer"); return ([], .adsbFi) })
        XCTAssertEqual(source, .server)
        XCTAssertFalse(flights.isEmpty, "no aircraft within 50 nm of the area centre")
        print("LIVE nearby: \(flights.count) flights, nearest \(flights.first.map { "\($0.id) \($0.callsign) \($0.typeCode) \($0.altitude) ft" } ?? "-")")

        let airline = try XCTUnwrap(flights.first { $0.looksLikeAirline && AircraftID.hex($0.id, allowNonICAO: false) != nil },
                                    "no airline flight to look up")

        // Route and aircraft: the adsbdb decoders, fed by the server.
        let (route, routeDefinitive) = await FlightService.fetchRoute(airline.callsign)
        XCTAssertTrue(routeDefinitive, "route lookup failed for \(airline.callsign)")
        print("LIVE route \(airline.callsign): \(route.map { "\($0.from.code)-\($0.to.code) \($0.airline ?? "")" } ?? "none known")")
        let (aircraft, aircraftDefinitive) = await FlightService.fetchAircraft(airline.id)
        XCTAssertTrue(aircraftDefinitive, "aircraft lookup failed for \(airline.id)")
        print("LIVE aircraft \(airline.id): \(aircraft?.model ?? "-") / \(aircraft?.owner ?? "-")")

        // Track: the server records every flight in its area.
        let trackResponse = await server.get(["v1", "track", airline.id])
        XCTAssertEqual(trackResponse?.status, 200)
        let track = FlightTrack(data: trackResponse?.data ?? Data(), current: airline.geoPoint)
        XCTAssertNotNil(track, "the server's track didn't parse as a FlightTrack")
        print("LIVE track \(airline.id): \(track?.points.count ?? 0) points, starts at \(Int(track?.startAltitudeFt ?? -1)) ft")
        let viaService = await FlightDetailService.track(hex: airline.id, current: airline.geoPoint)
        XCTAssertNotNil(viaService)

        // ACARS: the Airframes decoders behind /v1/acars.
        let acars = AcarsService(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let (acarsResult, _) = try await acars.refresh(hex: airline.id, callsign: airline.callsign, flightNumber: route?.flightNo,
                                                       position: airline.geoPoint, cursor: AcarsCursor())
        let acarsServer = await server.get(["v1", "acars", airline.id], limit: ResponseLimit.airframes)
        XCTAssertEqual(acarsServer?.status, 200)
        XCTAssertNotNil(try? AirframesAPI.decoder().decode(ServerAcarsResponse.self, from: acarsServer?.data ?? Data()))
        print("LIVE acars \(airline.id): \(String(describing: acarsResult).prefix(120))")

        // Weather: aviationweather.gov's format, from the server.
        let airport = try XCTUnwrap(AirportDB.nearest(to: GeoPoint(lat: centre.centerLat, lon: centre.centerLon), within: 80))
        let station = try XCTUnwrap(WeatherStation.icao(for: airport))
        let weather = WeatherService(directory: nil)
        let metars = await weather.metars([station])
        XCTAssertNotNil(metars[station], "no METAR for \(station)")
        let tafs = await weather.tafs([station])
        print("LIVE weather \(station): METAR \(metars[station]?.raw.prefix(60) ?? "-") | TAF \(tafs[station] != nil ? "yes" : "none")")

        // Logbook sync.
        let page = await server.sightings(after: nil, limit: 50)
        let sightings = try XCTUnwrap(page, "sightings page didn't decode")
        XCTAssertFalse(sightings.sightings.isEmpty)
        XCTAssertEqual(sightings.sightings.compactMap(LogEntry.init(server:)).count, sightings.sightings.count)
        print("LIVE sightings: \(sightings.sightings.count) on the first page, more: \(sightings.next != nil)")

        // Watch (the app posts this when a flight's detail opens).
        let watch = await server.get(["v1", "watch"])
        XCTAssertEqual(watch?.status, 200)
        await server.watch(hex: airline.id, callsign: airline.callsign)
        let available = await server.isAvailable
        let problem = await server.lastProblem
        XCTAssertTrue(available, "a request failed: \(problem ?? "")")
    }
}
