import XCTest

// MARK: - Fake network

/// Answers requests from a per-test table instead of the network, and records every request.
final class FakeServerProtocol: URLProtocol {
    enum Reply {
        case json(Int, String, headers: [String: String] = [:])
        case body(Int, Data, contentType: String)
        /// 302 to `URL`.
        case redirect(URL)
        /// Never answers; fails with `.timedOut` after the request's timeout.
        case hang
    }

    private static let lock = NSLock()
    private static var routes: [(match: (URLRequest) -> Bool, reply: Reply)] = []
    private static var recorded: [URLRequest] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        routes = []
        recorded = []
    }

    /// Adds a reply for requests whose URL contains `fragment` (the latest route wins).
    static func on(_ fragment: String, _ reply: Reply) {
        lock.lock(); defer { lock.unlock() }
        routes.insert(({ $0.url?.absoluteString.contains(fragment) == true }, reply), at: 0)
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func requests(to host: String) -> [URLRequest] { requests.filter { $0.url?.host == host } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var hangTask: Task<Void, Never>?

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let reply = Self.routes.first { $0.match(request) }?.reply
        Self.lock.unlock()
        let url = request.url!
        switch reply {
        case .json(let status, let body, let headers)?:
            send(status, Data(body.utf8), headers.merging(["Content-Type": "application/json"]) { a, _ in a })
        case .body(let status, let data, let type)?:
            send(status, data, ["Content-Type": type])
        case .redirect(let to)?:
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": to.absoluteString])!
            // Like a careless HTTP stack: the new request carries every original header.
            var next = URLRequest(url: to)
            next.allHTTPHeaderFields = request.allHTTPHeaderFields
            next.httpMethod = request.httpMethod
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            // Reached when the redirect is refused: the 302 itself is the answer.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        case .hang?:
            let wait = request.timeoutInterval
            hangTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                self.client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            }
        case nil:
            send(404, Data(#"{"error":"not found"}"#.utf8), ["Content-Type": "application/json"])
        }
    }

    override func stopLoading() { hangTask?.cancel() }

    private func send(_ status: Int, _ data: Data, _ headers: [String: String]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
}

// MARK: - Tests

final class FlightDeskServerTests: XCTestCase {
    private let base = "https://fd.example.test"
    private let token = "generic-test-token-0123456789"
    private var clock = TestClock()

    override func setUp() {
        super.setUp()
        FakeServerProtocol.reset()
        clock = TestClock()
    }

    private func makeServer(enabled: Bool = true, url: String? = nil, tokens: SecretStore? = nil,
                            timeout: TimeInterval = 0.3) -> FlightDeskServer {
        let settings = ServerSettings(enabled: enabled, url: url ?? base)
        let clock = clock
        return FlightDeskServer(session: FlightDeskServer.makeSession(protocolClasses: [FakeServerProtocol.self],
                                                                      timeout: timeout, countRequests: false),
                                settings: { settings }, tokens: tokens ?? MemorySecretStore(token),
                                backoff: 90, timeout: timeout, now: { clock.now })
    }

    /// A `/v1/nearby` body written by hand with made-up aircraft.
    private let nearbyFixture = """
    {"source":"area","feed":"adsb.fi","time":1800000000.5,"age":1.2,"cache":"",
     "flights":[
      {"id":"abc123","callsign":"TST101","reg":"N101TS","typeCode":"B738","altitude":12000,"verticalRate":-640,
       "speed":310.5,"track":271.2,"lat":45.1,"lon":-90.2,"distance":6.4,"bearing":75.5,"squawk":"1200",
       "onGround":false,"positionTime":1800000000.1,"desc":"BOEING 737-800","ownOp":"EXAMPLE AIR","year":2012,
       "navQnh":1013.2,"category":"A3"},
      {"id":"~0f0f0f","callsign":"","reg":"~0F0F0F","typeCode":"","altitude":2500,"verticalRate":0,"speed":95,
       "lat":45.0,"lon":-90.0,"distance":2.1,"bearing":180,"onGround":false,"positionTime":1800000000},
      {"id":"def456","callsign":"N456EX","reg":"N456EX","typeCode":"C172","altitude":"bad"},
      {"id":"not-a-hex","callsign":"X","reg":"X","typeCode":"","altitude":1,"verticalRate":0,"speed":1,
       "lat":45,"lon":-90,"distance":1,"bearing":1}
     ]}
    """

    private func feedsNeverCalled() async throws -> ([Flight], LiveFeed) {
        XCTFail("the public feeds shouldn't be asked")
        return ([], .adsbFi)
    }

    // MARK: Address and token validation

    func testAcceptsHTTPSAndLocalHTTPOnly() {
        func ok(_ s: String) -> String? { try? ServerAddress.check(s).get().absoluteString }
        XCTAssertEqual(ok("https://flightdesk.example.com"), "https://flightdesk.example.com")
        XCTAssertEqual(ok("flightdesk.example.com/"), "https://flightdesk.example.com", "https is assumed, trailing slash dropped")
        XCTAssertEqual(ok("HTTPS://Flightdesk.example.com:8443/fd///"), "https://Flightdesk.example.com:8443/fd")
        XCTAssertNotNil(ok("http://localhost:8080"))
        XCTAssertNotNil(ok("http://raspberrypi.local"))
        XCTAssertNotNil(ok("http://127.0.0.1:8080"))
        XCTAssertNotNil(ok("http://10.1.2.3"))
        XCTAssertNotNil(ok("http://172.16.0.5"))
        XCTAssertNotNil(ok("http://172.31.255.1"))
        XCTAssertNotNil(ok("http://192.168.1.50:8080"))
        XCTAssertNotNil(ok("http://169.254.10.10"))
        XCTAssertNotNil(ok("http://100.100.1.1"), "carrier-grade NAT (Tailscale)")
        XCTAssertNotNil(ok("http://[::1]:8080"))
        XCTAssertNotNil(ok("http://[fd12:3456::1]"))
        XCTAssertNotNil(ok("http://[fe80::1]"))

        XCTAssertEqual(ServerAddress.check("http://flightdesk.example.com"), .failure(.insecure))
        XCTAssertEqual(ServerAddress.check("http://172.32.0.1"), .failure(.insecure))
        XCTAssertEqual(ServerAddress.check("http://8.8.8.8"), .failure(.insecure))
        XCTAssertEqual(ServerAddress.check("http://192.168.1"), .failure(.insecure), "not an IP address, not local")
        XCTAssertEqual(ServerAddress.check("http://10.0.0.1.example.com"), .failure(.insecure))
        XCTAssertEqual(ServerAddress.check("http://[2001:db8::1]"), .failure(.insecure))
        XCTAssertEqual(ServerAddress.check("   "), .failure(.empty))
        XCTAssertEqual(ServerAddress.check("ftp://example.com"), .failure(.invalid))
        XCTAssertEqual(ServerAddress.check("https://user:pass@example.com"), .failure(.invalid))
        XCTAssertEqual(ServerAddress.check("https://example.com/?token=x"), .failure(.invalid))
        XCTAssertEqual(ServerAddress.check("https://example.com/#x"), .failure(.invalid))
        XCTAssertEqual(ServerAddress.check("https://exa mple.com"), .failure(.invalid))

        XCTAssertFalse(ServerSettings(enabled: true, url: "http://example.com").isActive)
        XCTAssertTrue(ServerSettings(enabled: true, url: "https://example.com").isActive)
        XCTAssertFalse(ServerSettings(enabled: false, url: "https://example.com").isActive)
    }

    func testTokenNormalization() {
        XCTAssertEqual(ServerToken.normalized("  abc_DEF-123.~  \n"), "abc_DEF-123.~")
        XCTAssertNil(ServerToken.normalized(""))
        XCTAssertNil(ServerToken.normalized("abc def"), "no spaces inside")
        XCTAssertNil(ServerToken.normalized("abc\r\nX-Evil: 1"), "no header injection")
        XCTAssertNil(ServerToken.normalized("tökén"))
        XCTAssertNil(ServerToken.normalized(String(repeating: "a", count: 513)))
    }

    func testOriginsAndURLBuilding() throws {
        XCTAssertEqual(ServerAddress.origin(of: URL(string: "https://Example.com/a")!), "https://example.com:443")
        XCTAssertEqual(ServerAddress.origin(of: URL(string: "https://example.com:443/b")!),
                       ServerAddress.origin(of: URL(string: "https://example.com/c")!))
        XCTAssertNotEqual(ServerAddress.origin(of: URL(string: "http://example.com")!),
                          ServerAddress.origin(of: URL(string: "https://example.com")!))
        XCTAssertNotEqual(ServerAddress.origin(of: URL(string: "https://example.com:8443")!),
                          ServerAddress.origin(of: URL(string: "https://example.com")!))

        let b = try ServerAddress.check("https://example.com/fd").get()
        XCTAssertEqual(FlightDeskServer.url(b, ["v1", "route", "TST101"])?.absoluteString, "https://example.com/fd/v1/route/TST101")
        XCTAssertEqual(FlightDeskServer.url(b, ["v1", "metar"], query: [("ids", "KAAA,KBBB")])?.absoluteString,
                       "https://example.com/fd/v1/metar?ids=KAAA%2CKBBB")
        XCTAssertEqual(FlightDeskServer.url(b, ["v1", "track", "../x?y"])?.absoluteString,
                       "https://example.com/fd/v1/track/..%2Fx%3Fy", "a segment can't add path or query")
        XCTAssertNil(FlightDeskServer.url(b, ["v1", ".."]))
    }

    // MARK: Decoding

    func testNearbyJSONMapsToFlights() throws {
        let r = try JSONDecoder().decode(ServerNearbyResponse.self, from: Data(nearbyFixture.utf8))
        XCTAssertEqual(r.source, "area")
        XCTAssertEqual(r.flights.map(\.id), ["abc123", "~0f0f0f"], "malformed and invalid-hex entries are skipped")
        let f = r.flights[0]
        XCTAssertEqual(f.callsign, "TST101")
        XCTAssertEqual(f.reg, "N101TS")
        XCTAssertEqual(f.typeCode, "B738")
        XCTAssertEqual(f.altitude, 12000)
        XCTAssertEqual(f.verticalRate, -640)
        XCTAssertEqual(f.speed, 310.5)
        XCTAssertEqual(f.track, 271.2)
        XCTAssertEqual(f.lat, 45.1)
        XCTAssertEqual(f.lon, -90.2)
        XCTAssertEqual(f.distance, 6.4)
        XCTAssertEqual(f.bearing, 75.5)
        XCTAssertEqual(f.squawk, "1200")
        XCTAssertNil(f.route)
        XCTAssertNil(f.aircraft)
        XCTAssertTrue(f.looksLikeAirline)
        XCTAssertNil(r.flights[1].track)
        XCTAssertNil(r.flights[1].squawk)
    }

    func testSightingsMapAndMergeIntoTheLog() throws {
        let json = """
        {"sightings":[
          {"hex":"abc123","registration":"N101TS","typeCode":"b738","operatorName":"EXAMPLE AIR","airlineICAO":"TST",
           "firstSeen":1799990000,"lastSeen":1800001000,"sightings":4,"callsigns":["TST100","TST101"],
           "closestNM":3.2,"closestAt":1800000500,"maxAltitude":36000,"routes":["AAA-BBB","bad route"]},
          {"hex":"def456","registration":"DEF456","typeCode":"","operatorName":"","firstSeen":1800000000,
           "lastSeen":1800000100,"sightings":1,"callsigns":[],"closestNM":9,"closestAt":1800000000,"maxAltitude":2500,"routes":[]},
          {"hex":"zzz","firstSeen":1,"lastSeen":2}
        ],"next":{"since":1800001000,"after":"def456"},"serverTime":1800002000}
        """
        let page = try JSONDecoder().decode(ServerSightingsPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.next, ServerSightingsPage.Cursor(since: 1_800_001_000, after: "def456"))
        let remote = page.sightings.compactMap(LogEntry.init(server:))
        XCTAssertEqual(remote.map(\.hex), ["abc123", "def456"])
        let a = remote[0]
        XCTAssertEqual(a.typeCode, "B738")
        XCTAssertEqual(a.airlineICAO, "TST")
        XCTAssertEqual(a.routes, ["AAA-BBB"])
        XCTAssertEqual(a.closestNM, .greatestFiniteMagnitude, "the server's distance is from its area centre, not the user")
        XCTAssertEqual(remote[1].registration, "", "a registration that's just the hex is dropped")

        // Local: seen once, earlier, nearer, with an older callsign.
        let local = Flight(adsb: try JSONDecoder().decode(ADSBAircraft.self, from: Data("""
        {"hex":"abc123","flight":"TST099","r":"N101TS","t":"B738","alt_baro":5000,"gs":250,"lat":45,"lon":-90,"dst":1.5,"dir":10}
        """.utf8)))!
        var log = SpottingLog()
        log.record([local], at: Date(timeIntervalSince1970: 1_799_000_000))
        let change = log.absorb(remote)
        XCTAssertEqual(change.added, ["def456"])
        XCTAssertTrue(change.any)
        let merged = try XCTUnwrap(log["abc123"])
        XCTAssertEqual(merged.firstSeen, Date(timeIntervalSince1970: 1_799_000_000))
        XCTAssertEqual(merged.lastSeen, Date(timeIntervalSince1970: 1_800_001_000))
        XCTAssertEqual(merged.sightings, 4)
        XCTAssertEqual(merged.maxAltitude, 36000)
        XCTAssertEqual(merged.closestNM, 1.5, "the local pass is kept")
        XCTAssertEqual(merged.callsigns, ["TST099", "TST100", "TST101"])
        XCTAssertEqual(merged.operatorName, "EXAMPLE AIR")

        XCTAssertFalse(log.absorb(remote).any, "absorbing the same entries again changes nothing")
    }

    // MARK: Source order and fallback

    func testServerAnswersNearbyBeforeTheFeeds() async throws {
        FakeServerProtocol.on("/v1/nearby", .json(200, nearbyFixture))
        let server = makeServer()
        let (list, source) = try await FlightService.nearbyFromSources(
            lat: 45.12345, lon: -90.98765, radiusNM: 25, receiver: ReceiverSettings(), server: server,
            local: { XCTFail("no receiver configured"); return [] }, feeds: feedsNeverCalled)
        XCTAssertEqual(source, .server)
        XCTAssertEqual(list.map(\.id), ["~0f0f0f", "abc123"], "nearest first")
        let r = try XCTUnwrap(FakeServerProtocol.requests.first)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(q.first { $0.name == "lat" }?.value, "45.12", "position rounded like for the public feeds")
        XCTAssertEqual(q.first { $0.name == "lon" }?.value, "-90.99")
        XCTAssertEqual(q.first { $0.name == "radius" }?.value, "25")
        XCTAssertEqual(r.timeoutInterval, 0.3, accuracy: 0.001)
    }

    func testServerErrorFallsBackToFeedsThenBacksOff() async throws {
        FakeServerProtocol.on("/v1/nearby", .body(500, Data("oops".utf8), contentType: "text/plain"))
        let server = makeServer()
        var feedCalls = 0
        func run() async throws -> DataSource {
            try await FlightService.nearbyFromSources(lat: 45, lon: -90, radiusNM: 25, receiver: ReceiverSettings(), server: server,
                                                      local: { [] }, feeds: { feedCalls += 1; return ([], .adsbLol) }).1
        }
        let first = try await run()
        XCTAssertEqual(first, .feed(.adsbLol))
        XCTAssertEqual(FakeServerProtocol.requests.count, 1)
        let benched = await server.isAvailable
        XCTAssertFalse(benched)

        // Within the back-off: straight to the feeds, no request to the server.
        clock.advance(60)
        _ = try await run()
        XCTAssertEqual(FakeServerProtocol.requests.count, 1)
        XCTAssertEqual(feedCalls, 2)

        // After it, the server is tried again and serves.
        clock.advance(31)
        FakeServerProtocol.on("/v1/nearby", .json(200, nearbyFixture))
        let third = try await run()
        XCTAssertEqual(third, .server)
        XCTAssertEqual(FakeServerProtocol.requests.count, 2)
        XCTAssertEqual(feedCalls, 2)
    }

    func testTimeoutFallsBackAndBacksOff() async throws {
        FakeServerProtocol.on("/v1/nearby", .hang)
        let server = makeServer(timeout: 0.3)
        let start = Date()
        let (_, source) = try await FlightService.nearbyFromSources(lat: 45, lon: -90, radiusNM: 25, receiver: ReceiverSettings(),
                                                                    server: server, local: { [] }, feeds: { ([], .adsbFi) })
        XCTAssertEqual(source, .feed(.adsbFi))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let available = await server.isAvailable
        XCTAssertFalse(available)
        let until = await server.skippedUntil
        XCTAssertEqual(until, clock.now.addingTimeInterval(90))
    }

    func testUnreadableOrUnauthorizedBenchesButUpstreamErrorDoesNot() async throws {
        // A JSON 502 is the server saying one upstream is down: fall back, but keep using the server.
        FakeServerProtocol.on("/v1/route/", .json(502, #"{"error":"upstream unavailable"}"#))
        let server = makeServer()
        let r1 = await server.get(["v1", "route", "TST101"])
        XCTAssertNil(r1)
        var available = await server.isAvailable
        XCTAssertTrue(available)

        // A proxy's HTML 502 means the server itself is down.
        FakeServerProtocol.on("/v1/route/", .body(502, Data("<html>Bad Gateway</html>".utf8), contentType: "text/html"))
        _ = await server.get(["v1", "route", "TST101"])
        available = await server.isAvailable
        XCTAssertFalse(available)

        await server.reset()
        FakeServerProtocol.on("/v1/aircraft/", .json(401, #"{"error":"unauthorized"}"#))
        _ = await server.get(["v1", "aircraft", "abc123"])
        available = await server.isAvailable
        XCTAssertFalse(available)
        let problem = await server.lastProblem
        XCTAssertEqual(problem, "the server rejected the token")

        await server.reset()
        FakeServerProtocol.on("/v1/nearby", .json(200, "[1,2,3]"))
        let n = await server.nearby(lat: 45, lon: -90, radiusNM: 25)
        XCTAssertNil(n)
        available = await server.isAvailable
        XCTAssertFalse(available, "an unreadable answer isn't a FlightDesk server")
    }

    func testRateLimitHonoursRetryAfter() async {
        FakeServerProtocol.on("/v1/stats", .json(429, #"{"error":"slow down"}"#, headers: ["Retry-After": "240"]))
        let server = makeServer()
        _ = await server.get(["v1", "stats"])
        let until = await server.skippedUntil
        XCTAssertEqual(until, clock.now.addingTimeInterval(240))
    }

    func test404IsADefinitiveAnswer() async throws {
        FakeServerProtocol.on("/v1/route/", .json(404, #"{"response":"unknown callsign"}"#))
        let server = makeServer()
        let r = await server.get(["v1", "route", "ZZZ999"])
        XCTAssertEqual(r?.status, 404)
        let available = await server.isAvailable
        XCTAssertTrue(available)
    }

    func testReceiverKeepsItsPriority() async throws {
        await FeedHealth.shared.receiverSucceeded()
        FakeServerProtocol.on("/v1/nearby", .json(200, nearbyFixture))
        let receiver = ReceiverSettings(enabled: true, url: "http://receiver.local")
        let mine = try JSONDecoder().decode(ServerNearbyResponse.self, from: Data(nearbyFixture.utf8)).flights
        let (list, source) = try await FlightService.nearbyFromSources(
            lat: 45, lon: -90, radiusNM: 25, receiver: receiver, server: makeServer(),
            local: { mine }, feeds: feedsNeverCalled)
        XCTAssertEqual(source, .receiver)
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(FakeServerProtocol.requests.isEmpty, "the server isn't asked while the receiver answers")

        // Receiver fails: the server comes next, before the feeds.
        let (_, next) = try await FlightService.nearbyFromSources(
            lat: 45, lon: -90, radiusNM: 25, receiver: receiver, server: makeServer(),
            local: { throw URLError(.cannotConnectToHost) }, feeds: feedsNeverCalled)
        XCTAssertEqual(next, .server)
    }

    func testDisabledServerSendsNothingAndLeavesTheKeychainAlone() async throws {
        let tokens = MemorySecretStore(token)
        let server = makeServer(enabled: false, tokens: tokens)
        let (_, source) = try await FlightService.nearbyFromSources(lat: 45, lon: -90, radiusNM: 25, receiver: ReceiverSettings(),
                                                                    server: server, local: { [] }, feeds: { ([], .adsbFi) })
        XCTAssertEqual(source, .feed(.adsbFi))
        await server.watch(hex: "abc123", callsign: "TST101")
        XCTAssertTrue(FakeServerProtocol.requests.isEmpty)
        XCTAssertEqual(tokens.reads, 0)

        // No token, or an insecure address: also unused.
        let noToken = makeServer(tokens: MemorySecretStore(nil))
        let r1 = await noToken.get(["v1", "stats"])
        XCTAssertNil(r1)
        let insecure = makeServer(url: "http://flightdesk.example.com")
        let r2 = await insecure.get(["v1", "stats"])
        XCTAssertNil(r2)
        XCTAssertTrue(FakeServerProtocol.requests.isEmpty)
    }

    // MARK: Security

    func testRedirectToAnotherHostIsRefusedAndTheTokenStays() async throws {
        FakeServerProtocol.on("/v1/aircraft/", .redirect(URL(string: "https://elsewhere.example.test/steal")!))
        FakeServerProtocol.on("elsewhere.example.test", .json(200, #"{"response":{"aircraft":{}}}"#))
        let server = makeServer()
        let r = await server.get(["v1", "aircraft", "abc123"])
        XCTAssertNil(r, "the redirect isn't an answer")
        XCTAssertTrue(FakeServerProtocol.requests(to: "elsewhere.example.test").isEmpty, "the other host is never contacted")
        XCTAssertFalse(FakeServerProtocol.requests.contains { $0.url?.host != "fd.example.test" })
        let available = await server.isAvailable
        XCTAssertFalse(available)

        // Also refused: a downgrade to http on the same host (another origin).
        await server.reset()
        FakeServerProtocol.reset()
        FakeServerProtocol.on("/v1/aircraft/", .redirect(URL(string: "http://fd.example.test/v1/aircraft/abc123")!))
        let r2 = await server.get(["v1", "aircraft", "abc123"])
        XCTAssertNil(r2)
        XCTAssertEqual(FakeServerProtocol.requests.count, 1)
    }

    func testDelegateOnlyFollowsSameOriginRedirects() {
        let delegate = ServerSessionDelegate(countRequests: false)
        let session = URLSession(configuration: .ephemeral)
        var original = URLRequest(url: URL(string: "https://fd.example.test/v1/stats")!)
        original.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        func decide(_ target: String) -> URLRequest?? {
            var out: URLRequest?? = .none
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                newRequest: URLRequest(url: URL(string: target)!)) { out = .some($0) }
            return out
        }
        XCTAssertEqual(decide("https://other.example.test/v1/stats"), .some(nil))
        XCTAssertEqual(decide("https://fd.example.test:8443/v1/stats"), .some(nil))
        XCTAssertEqual(decide("http://fd.example.test/v1/stats"), .some(nil))
        let same = decide("https://FD.example.test/v2/stats")
        XCTAssertEqual(same??.url?.path, "/v2/stats")
        XCTAssertEqual(same??.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        task.cancel()
    }

    func testOversizedResponseIsRejected() async {
        FakeServerProtocol.on("/v1/stats", .json(200, String(repeating: " ", count: 40_000) + "{}"))
        let server = makeServer()
        let r = await server.get(["v1", "stats"], limit: 20_000)
        XCTAssertNil(r)
        let available = await server.isAvailable
        XCTAssertFalse(available)
    }

    func testWatchIsPostedOncePerFlight() async {
        FakeServerProtocol.on("/v1/watch/", .json(202, #"{"watch":{"hex":"abc123"},"active":1,"max":20}"#))
        let server = makeServer()
        await server.watch(hex: "ABC123", callsign: "TST101")
        await server.watch(hex: "abc123", callsign: "TST101 ")
        await server.watch(hex: "~abc123", callsign: "TST101")
        XCTAssertEqual(FakeServerProtocol.requests.count, 1)
        let r = FakeServerProtocol.requests[0]
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.path, "/v1/watch/abc123")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")

        await server.watch(hex: "abc123", callsign: "TST102")
        XCTAssertEqual(FakeServerProtocol.requests.count, 2, "a new callsign is a new flight")
    }

    func testFailedWatchIsRetriedLater() async {
        FakeServerProtocol.on("/v1/watch/", .body(500, Data(), contentType: "text/plain"))
        let server = makeServer()
        await server.watch(hex: "abc123", callsign: "TST101")
        clock.advance(91)
        FakeServerProtocol.on("/v1/watch/", .json(202, "{}"))
        await server.watch(hex: "abc123", callsign: "TST101")
        await server.watch(hex: "abc123", callsign: "TST101")
        XCTAssertEqual(FakeServerProtocol.requests.count, 2)
    }

    func testTokenIsReadFromTheStoreAndCachedBriefly() async {
        FakeServerProtocol.on("/v1/stats", .json(200, "{}"))
        let tokens = MemorySecretStore(token)
        let server = makeServer(tokens: tokens)
        _ = await server.get(["v1", "stats"])
        _ = await server.get(["v1", "stats"])
        XCTAssertEqual(tokens.reads, 1)
        try? tokens.write("rotated-token")
        clock.advance(31)
        _ = await server.get(["v1", "stats"])
        XCTAssertEqual(FakeServerProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer rotated-token")
    }

    // MARK: Connection test

    func testConnectionTestReportsStats() async {
        FakeServerProtocol.on("/healthz", .json(200, #"{"ok":true}"#))
        FakeServerProtocol.on("/v1/stats", .json(200, """
        {"db":{"totalBytes":543320},"poller":{"enabled":true,"aircraft":156},"version":"test-1"}
        """))
        let session = FlightDeskServer.makeSession(protocolClasses: [FakeServerProtocol.self], countRequests: false)
        let r = await FlightDeskServer.test(url: base, token: token, session: session)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(r.message.contains("156 aircraft"), r.message)
        XCTAssertTrue(r.message.contains("database"), r.message)
        XCTAssertTrue(r.detail?.contains("test-1") == true)
        XCTAssertNil(FakeServerProtocol.requests(to: "fd.example.test").first { $0.url?.path == "/healthz" }?
            .value(forHTTPHeaderField: "Authorization"), "/healthz is asked without the token")
        XCTAssertEqual(FakeServerProtocol.requests.first { $0.url?.path == "/v1/stats" }?
            .value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
    }

    func testConnectionTestExplainsFailures() async {
        let session = FlightDeskServer.makeSession(protocolClasses: [FakeServerProtocol.self], countRequests: false)
        FakeServerProtocol.on("/healthz", .json(200, #"{"ok":true}"#))
        FakeServerProtocol.on("/v1/stats", .json(401, #"{"error":"unauthorized"}"#))
        var r = await FlightDeskServer.test(url: base, token: token, session: session)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("rejected the token"), r.message)

        FakeServerProtocol.on("/healthz", .body(200, Data("<html></html>".utf8), contentType: "text/html"))
        r = await FlightDeskServer.test(url: base, token: token, session: session)
        XCTAssertTrue(r.message.contains("isn’t a FlightDesk server"), r.message)

        r = await FlightDeskServer.test(url: "http://flightdesk.example.com", token: token, session: session)
        XCTAssertEqual(r.message, ServerAddress.Problem.insecure.message)
        r = await FlightDeskServer.test(url: base, token: "two words", session: session)
        XCTAssertFalse(r.ok)
    }

    // MARK: Token storage

    func testMemorySecretStoreRoundTrip() throws {
        let store = MemorySecretStore()
        XCTAssertNil(store.read())
        try store.write("abc")
        XCTAssertEqual(store.read(), "abc")
        try store.write("")
        XCTAssertNil(store.read())
    }

    func testKeychainRoundTrip() throws {
        let store = KeychainSecretStore(service: "flightdesk.tests.\(UUID().uuidString)", account: "token", accessGroup: nil)
        do {
            try store.write("first-value")
        } catch {
            throw XCTSkip("No usable keychain in this test host: \(error.localizedDescription)")
        }
        defer { try? store.write(nil) }
        XCTAssertEqual(store.read(), "first-value")
        try store.write("second-value")
        XCTAssertEqual(store.read(), "second-value", "writing replaces the item")
        try store.write(nil)
        XCTAssertNil(store.read())
    }

    // MARK: Settings

    func testSettingsDecodeTolerantly() throws {
        let s = try JSONDecoder().decode(ServerSettings.self, from: Data(#"{"enabled":true,"url":5}"#.utf8))
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.url, "")
        XCTAssertTrue(s.syncLogbook)
        let data = try JSONEncoder().encode(ServerSettings(enabled: true, url: "https://example.com", syncLogbook: false))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).lowercased().contains("token"), "the token is never in settings")
    }

    func testRequestUsageListsTheServer() {
        XCTAssertEqual(ApiService.flightdeskServer.title, "FlightDesk server")
        XCTAssertNil(ApiService.flightdeskServer.dailyLimit)
        XCTAssertEqual(RefreshCadence.interval(source: .server, counts: [:], paused: [.adsbFi, .adsbLol]), RefreshCadence.live)
    }
}
