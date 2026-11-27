import XCTest
import CoreGraphics
import ImageIO

/// Input validation, bounded decoding and the caches shared between the app and the widget.
final class HardeningTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fd-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func testDefaults() -> UserDefaults {
        let name = "fd-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func flight(_ hex: String, callsign: String = "DAL12", lat: Double = 40, lon: Double = -100,
                        dist: Double = 5, alt: Int = 30_000, track: Double = 90, gs: Double = 450) -> Flight {
        let json = """
        {"hex":"\(hex)","flight":"\(callsign)","t":"B738","alt_baro":\(alt),"gs":\(gs),"track":\(track),
         "lat":\(lat),"lon":\(lon),"dst":\(dist),"dir":90,"baro_rate":0}
        """
        return Flight(adsb: try! JSONDecoder().decode(ADSBAircraft.self, from: Data(json.utf8)))!
    }

    // MARK: Identifiers

    func testHexValidation() {
        XCTAssertEqual(AircraftID.hex("A1B2C3"), "a1b2c3")
        XCTAssertEqual(AircraftID.hex("~a1b2c3"), "~a1b2c3")
        XCTAssertNil(AircraftID.hex("~a1b2c3", allowNonICAO: false))
        XCTAssertNil(AircraftID.hex("a1b2c"))
        XCTAssertNil(AircraftID.hex("a1b2c3d"))
        XCTAssertNil(AircraftID.hex("g1b2c3"))
        XCTAssertNil(AircraftID.hex("a1b2c3/"))
        XCTAssertNil(AircraftID.hex("../../x"))
        XCTAssertNil(AircraftID.hex("～a1b2c3"))
        XCTAssertNil(AircraftID.hex("ａ1b2c3"), "fullwidth letters are not ASCII hex")
        XCTAssertNil(AircraftID.hex(""))
    }

    func testCallsignValidation() {
        XCTAssertEqual(AircraftID.callsign(" swa2210 "), "SWA2210")
        XCTAssertEqual(AircraftID.callsign("N1"), "N1")
        XCTAssertNil(AircraftID.callsign("A"))
        XCTAssertNil(AircraftID.callsign("ABCDEFGHI"))
        XCTAssertNil(AircraftID.callsign("DAL/12"))
        XCTAssertNil(AircraftID.callsign("DAL 12"))
        XCTAssertNil(AircraftID.callsign("DAL12?x=1"))
        XCTAssertNil(AircraftID.callsign("ÄBC12"))
    }

    func testWatchlistAndAlertDBUseSharedHexRules() {
        XCTAssertEqual(WatchItem.normalize(" AE07E1 ", as: .hex), "ae07e1")
        XCTAssertNil(WatchItem.normalize("~ae07e1", as: .hex))
    }

    // MARK: URLs

    func testRemoteURLEncodesSegmentsAndQueries() throws {
        let u = try XCTUnwrap(RemoteURL.make("https://api.example.com/v0/callsign", ["A B/../c?d#e"]))
        XCTAssertEqual(u.absoluteString, "https://api.example.com/v0/callsign/A%20B%2F..%2Fc%3Fd%23e")
        XCTAssertEqual(u.host, "api.example.com")
        XCTAssertNil(RemoteURL.make("https://api.example.com/x", [".."]))
        XCTAssertNil(RemoteURL.make("https://api.example.com/x", [""]))
        XCTAssertNil(RemoteURL.make("http://api.example.com/x", ["a"]), "https only")

        let q = try XCTUnwrap(RemoteURL.make("https://example.com/search", query: [("q", "N1&x=2+3 #")]))
        XCTAssertEqual(q.query, "q=N1%26x%3D2%2B3%20%23")
        XCTAssertEqual(URLComponents(url: q, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "N1&x=2+3 #")
    }

    func testFeedURLsRejectInvalidInput() throws {
        XCTAssertNil(LiveFeed.adsbLol.hexURL("abc/../../x"))
        XCTAssertEqual(LiveFeed.adsbLol.hexURL("~ABC123")?.absoluteString, "https://api.adsb.lol/v2/hex/~abc123")
        XCTAssertEqual(LiveFeed.adsbFi.pointURL(lat: 39.7392, lon: -104.9903, radiusNM: 25)?.absoluteString,
                       "https://opendata.adsb.fi/api/v2/lat/39.74/lon/-104.99/dist/25")
        XCTAssertNil(LiveFeed.adsbLol.pointURL(lat: .nan, lon: 0, radiusNM: 25))
        XCTAssertNil(LiveFeed.adsbLol.pointURL(lat: 95, lon: 0, radiusNM: 25))
    }

    func testFlightLinkValidatesHex() throws {
        XCTAssertNil(FlightLink.url(for: "not-a-hex"))
        let u = try XCTUnwrap(FlightLink.url(for: "A1B2C3"))
        XCTAssertEqual(FlightLink.hex(from: u), "a1b2c3")
        XCTAssertNil(FlightLink.hex(from: URL(string: "flightdesk://flight/x/a1b2c3")!))
        XCTAssertNil(FlightLink.hex(from: URL(string: "flightdesk://flight/a1b2c3zz")!))
        XCTAssertNil(FlightLink.hex(from: URL(string: "https://flight/a1b2c3")!))
    }

    // MARK: Image guard

    private func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        }
        return ~c
    }

    /// A real PNG whose IHDR (with a valid CRC) claims `side`×`side` pixels: a decompression-bomb shape.
    private func pngClaiming(side: UInt32) -> Data {
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        var b = [UInt8](png(width: 64, height: 64))
        XCTAssertEqual(Array(b[12..<16]), Array("IHDR".utf8))
        b.replaceSubrange(16..<24, with: be(side) + be(side))
        b.replaceSubrange(29..<33, with: be(crc32(Array(b[12..<29]))))
        return Data(b)
    }

    private func png(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.1, blue: 0.2, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: width / 8, y: height / 8, width: width * 3 / 4, height: height * 3 / 4))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testHugeDeclaredDimensionsAreRejectedBeforeDecoding() {
        let bomb = pngClaiming(side: 100_000)
        XCTAssertGreaterThan(bomb.count, 200, "past isUsable's minimum size, so the guard is what rejects it")
        if let size = ImageGuard.pixelSize(bomb) {
            XCTAssertEqual(size.width, 100_000, "the header is read without decoding")
        }
        XCTAssertNil(ImageGuard.source(bomb, ImageGuard.logo))
        XCTAssertNil(ImageGuard.source(bomb, ImageGuard.photo))
        XCTAssertNil(ImageGuard.thumbnail(bomb, ImageGuard.photo, maxPixel: 100))
        XCTAssertFalse(AirlineLogos.isUsable(bomb))
    }

    func testImageLimits() throws {
        let small = png(width: 64, height: 64)
        XCTAssertNotNil(ImageGuard.source(small, ImageGuard.logo))
        XCTAssertEqual(ImageGuard.pixelSize(small)?.width, 64)

        // Too big for a logo, fine for a photo — decoded downscaled.
        let big = png(width: 1500, height: 1000)
        XCTAssertNil(ImageGuard.source(big, ImageGuard.logo))
        let thumb = try XCTUnwrap(ImageGuard.thumbnail(big, ImageGuard.photo, maxPixel: 600))
        XCTAssertEqual(max(thumb.width, thumb.height), 600)

        // Byte limit, and non-image data.
        var limits = ImageGuard.logo
        limits.maxBytes = small.count - 1
        XCTAssertNil(ImageGuard.source(small, limits))
        XCTAssertNil(ImageGuard.source(Data("<html></html>".utf8), ImageGuard.photo))
    }

    func testSVGSniffing() {
        XCTAssertTrue(ImageGuard.isPlainSVG(Data(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)))
        XCTAssertFalse(ImageGuard.isPlainSVG(png(width: 64, height: 64)), "a PNG served from an SVG URL")
        XCTAssertFalse(ImageGuard.isPlainSVG(Data(#"<!DOCTYPE svg [<!ENTITY a "aaaa">]><svg>&a;</svg>"#.utf8)))
        XCTAssertNil(AirlineLogos.rasterizedSVG(png(width: 64, height: 64)))
    }

    // MARK: NearbyCache

    func testNearbyCacheKeepsAreasApart() throws {
        let url = tmp.appendingPathComponent("nearby.json")
        let t0 = Date()
        NearbyCache.write([flight("aaaaaa")], key: "A", at: url, now: t0)
        NearbyCache.write([flight("bbbbbb"), flight("cccccc")], key: "B", source: .feed(.adsbFi), at: url, now: t0 + 5)

        XCTAssertEqual(NearbyCache.read(key: "A", maxAge: 20, at: url, now: t0 + 6)?.flights.map(\.id), ["aaaaaa"])
        XCTAssertEqual(NearbyCache.read(key: "B", maxAge: 20, at: url, now: t0 + 6)?.flights.count, 2)
        XCTAssertEqual(NearbyCache.read(key: "B", maxAge: 20, at: url, now: t0 + 6)?.source, .feed(.adsbFi))
        XCTAssertNil(NearbyCache.read(key: "C", maxAge: 20, at: url, now: t0 + 6))
        XCTAssertNil(NearbyCache.read(key: "A", maxAge: 20, at: url, now: t0 + 25), "too old")

        XCTAssertEqual(NearbyCache.latest(maxAge: 20, at: url, now: t0 + 6)?.key, "B", "newest wins")
        XCTAssertEqual(NearbyCache.latest(maxAge: 20, at: url, now: t0 + 22)?.key, "B")
        XCTAssertNil(NearbyCache.latest(maxAge: 20, at: url, now: t0 + 30))

        // Rewriting a key replaces it; the number of areas is bounded.
        NearbyCache.write([], key: "A", at: url, now: t0 + 10)
        XCTAssertEqual(NearbyCache.read(key: "A", maxAge: 20, at: url, now: t0 + 11)?.flights.count, 0)
        for i in 0..<10 { NearbyCache.write([], key: "K\(i)", at: url, now: t0 + 20 + Double(i)) }
        let all = try JSONDecoder().decode([NearbyCache.Entry].self, from: Data(contentsOf: url))
        XCTAssertEqual(all.count, NearbyCache.maxEntries)
        XCTAssertEqual(all.first?.key, "K9")
    }

    // MARK: LookupCache

    func testLookupCacheMergePrefersNewer() {
        let a = Airport(code: "DEN", city: "Denver", lat: 39.8, lon: -104.7)
        let old = RouteInfo(airline: "Old", flightNo: nil, from: a, to: a)
        let new = RouteInfo(airline: "New", flightNo: nil, from: a, to: a)
        var x = LookupCache.Store(), y = LookupCache.Store()
        x.routes["DAL1"] = .init(value: old, at: Date(timeIntervalSince1970: 100))
        y.routes["DAL1"] = .init(value: new, at: Date(timeIntervalSince1970: 200))
        x.routes["UAL2"] = .init(value: nil, at: Date(timeIntervalSince1970: 100))
        y.aircraft["abc123"] = .init(value: AircraftInfo(model: "B738", owner: nil), at: Date(timeIntervalSince1970: 50))
        let m = LookupCache.merge(x, y)
        XCTAssertEqual(m.routes["DAL1"]?.value?.airline, "New")
        XCTAssertEqual(LookupCache.merge(y, x).routes["DAL1"]?.value?.airline, "New", "order doesn't matter")
        XCTAssertNotNil(m.routes["UAL2"])
        XCTAssertEqual(m.aircraft["abc123"]?.value?.model, "B738")
    }

    func testLookupCacheSaveKeepsOtherProcessEntries() async throws {
        let url = tmp.appendingPathComponent("lookup.json")
        let cache = LookupCache(url: url)
        let a = Airport(code: "DEN", city: "Denver", lat: 39.8, lon: -104.7)
        await cache.record(route: RouteInfo(airline: "Mine", flightNo: nil, from: a, to: a), for: "DAL1")

        // Meanwhile the widget saved its own lookup.
        var theirs = LookupCache.Store()
        theirs.routes["SWA2"] = .init(value: RouteInfo(airline: "Theirs", flightNo: nil, from: a, to: a), at: Date())
        try JSONEncoder().encode(theirs).write(to: url)

        await cache.save()
        let disk = try JSONDecoder().decode(LookupCache.Store.self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(disk.routes.keys), ["DAL1", "SWA2"])
    }

    func testLookupCachePrunesOldest() {
        var s = LookupCache.Store()
        for i in 0..<1600 { s.routes["C\(i)"] = .init(value: nil, at: Date(timeIntervalSince1970: Double(i))) }
        let p = LookupCache.pruned(s)
        XCTAssertEqual(p.routes.count, 1000)
        XCTAssertNotNil(p.routes["C1599"])
        XCTAssertNil(p.routes["C0"])
    }

    // MARK: ApiBudget

    func testBudgetMergesProcesses() {
        let now = Date()
        let today = ApiBudget.day(of: now)
        var app = ApiBudget.State(day: today), widget = ApiBudget.State(day: today), stale = ApiBudget.State(day: "2000-01-01")
        app.counts = [.adsbLol: 3, .adsbdb: 1]
        widget.counts = [.adsbLol: 2]
        stale.counts = [.adsbLol: 99]
        app.pausedUntil = [.openSky: now + 60]
        widget.pausedUntil = [.openSky: now + 600, .adsbLol: now - 1]
        let m = ApiBudget.merge([app, widget, stale], day: today, now: now)
        XCTAssertEqual(m.counts[.adsbLol], 5, "yesterday's counts don't carry over")
        XCTAssertEqual(m.counts[.adsbdb], 1)
        XCTAssertEqual(m.pausedUntil[.openSky], now + 600, "the longest pause wins")
        XCTAssertNil(m.pausedUntil[.adsbLol], "expired pauses are dropped")
    }

    // MARK: Geocode cache

    func testGeocodeCacheIsBounded() {
        let d = testDefaults()
        d.set([1.0, 2.0, "Old"], forKey: "geo:legacy")
        for i in 0..<(GeocodeCache.maxEntries + 5) {
            GeocodeCache.store("q\(i)", .init(lat: 1, lon: 2, name: "P\(i)", at: Date(timeIntervalSince1970: Double(i))), defaults: d)
        }
        XCTAssertNil(GeocodeCache.lookup("q0", defaults: d), "oldest dropped")
        XCTAssertEqual(GeocodeCache.lookup("q204", defaults: d)?.name, "P204")
        XCTAssertNil(d.object(forKey: "geo:legacy"), "legacy per-query keys removed")
        let stored = d.data(forKey: GeocodeCache.key).flatMap { try? JSONDecoder().decode([String: GeocodeCache.Entry].self, from: $0) }
        XCTAssertEqual(stored?.count, GeocodeCache.maxEntries)
    }

    // MARK: Widget refresh

    func testWidgetRefreshOnlyOnMeaningfulChange() {
        let observer = GeoPoint(lat: 40, lon: -100)
        let t0 = Date()
        let drawn = [flight("aaaaaa", dist: 2), flight("bbbbbb", dist: 4, track: 180)]
        // The same aircraft where dead reckoning put them 30 s later.
        let moved = drawn.map { $0.projected(by: 30, observerLat: observer.lat, observerLon: observer.lon) }
        XCTAssertFalse(WidgetRefresh.isMeaningfulChange(drawn: drawn, drawnAt: t0, fresh: moved, now: t0 + 30, observer: observer))
        // A new aircraft.
        XCTAssertTrue(WidgetRefresh.isMeaningfulChange(drawn: drawn, drawnAt: t0, fresh: moved + [flight("cccccc", dist: 8)],
                                                       now: t0 + 30, observer: observer))
        // A big climb the projection didn't predict.
        var climbed = moved
        climbed[0].altitude += 2_000
        XCTAssertTrue(WidgetRefresh.isMeaningfulChange(drawn: drawn, drawnAt: t0, fresh: climbed, now: t0 + 30, observer: observer))
        // Timeline about to run out.
        XCTAssertTrue(WidgetRefresh.isMeaningfulChange(drawn: drawn, drawnAt: t0, fresh: drawn, now: t0 + 301, observer: observer))
        // Nothing in range before or after: no reload.
        XCTAssertFalse(WidgetRefresh.isMeaningfulChange(drawn: [], drawnAt: t0, fresh: [], now: t0 + 60, observer: observer))
    }

    func testWidgetShownListMatchesWidgetFilter() {
        let all = [flight("aaaaaa", callsign: "N172SP", dist: 1), flight("bbbbbb", callsign: "DAL12", dist: 3)]
        XCTAssertEqual(WidgetRefresh.shown(all, includeGA: false).map(\.id), ["bbbbbb"])
        XCTAssertEqual(WidgetRefresh.shown(all, includeGA: true).map(\.id), ["aaaaaa", "bbbbbb"])
    }

    func testWidgetDemand() {
        let d = testDefaults()
        let t0 = Date()
        let a = WidgetArea(lat: 39.7392, lon: -104.9903, radiusNM: 25, includeGA: true)
        XCTAssertEqual(a.lat, 39.74)
        WidgetDemand.record(a, now: t0, defaults: d)
        WidgetDemand.record(WidgetArea(lat: 39.741, lon: -104.99, radiusNM: 25, includeGA: true), now: t0 + 1, defaults: d)
        XCTAssertEqual(WidgetDemand.current(now: t0 + 2, defaults: d), [a], "same rounded area")
        WidgetDemand.record(WidgetArea(lat: 51.5, lon: 0, radiusNM: 10, includeGA: false), now: t0 + 2, defaults: d)
        XCTAssertEqual(WidgetDemand.current(now: t0 + 3, defaults: d).count, 2)
        XCTAssertTrue(WidgetDemand.current(now: t0 + WidgetDemand.lifetime + 10, defaults: d).isEmpty, "areas expire")
        WidgetDemand.clear(defaults: d)
        XCTAssertTrue(WidgetDemand.current(now: t0 + 3, defaults: d).isEmpty)
    }
}
