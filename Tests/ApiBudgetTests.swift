import XCTest

final class ApiBudgetTests: XCTestCase {
    func testServiceFromHost() {
        XCTAssertEqual(ApiService(host: "opendata.adsb.fi"), .adsbFi)
        XCTAssertEqual(ApiService(host: "api.adsb.lol"), .adsbLol)
        XCTAssertEqual(ApiService(host: "opensky-network.org"), .openSky)
        XCTAssertEqual(ApiService(host: "t.plnspttrs.net"), .planespotters)
        XCTAssertEqual(ApiService(host: "example.com"), .other)
    }

    func testPausesNearAllowance() {
        // adsb.lol: plenty left → no pause; nearly out → pause until reset.
        XCTAssertNil(ApiBudget.pauseInterval(service: .adsbLol, status: 200,
                                             headers: ["x-ratelimit-remaining": "215", "x-ratelimit-reset": "84106"]))
        XCTAssertEqual(ApiBudget.pauseInterval(service: .adsbLol, status: 200,
                                               headers: ["x-ratelimit-remaining": "40", "x-ratelimit-reset": "1200"]), 1200)
        // OpenSky rate-limited.
        XCTAssertEqual(ApiBudget.pauseInterval(service: .openSky, status: 429,
                                               headers: ["X-Rate-Limit-Retry-After-Seconds": "3600"]), 3600)
        // Services without a reserve are never paused by remaining counts.
        XCTAssertNil(ApiBudget.pauseInterval(service: .adsbFi, status: 200, headers: ["x-ratelimit-remaining": "0"]))
    }

    func testTrackCacheContinuation() {
        let end = TimedPoint(point: GeoPoint(lat: 42, lon: -88), time: Date(timeIntervalSince1970: 0))
        let oneHourLater = Date(timeIntervalSince1970: 3_600)
        XCTAssertTrue(TrackCache.isContinuation(from: end, to: GeoPoint(lat: 42, lon: -80), now: oneHourLater))   // ~357 nm
        XCTAssertFalse(TrackCache.isContinuation(from: end, to: GeoPoint(lat: 33.9, lon: -118.4), now: oneHourLater)) // LA
    }
}
