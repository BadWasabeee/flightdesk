// Shared HTTP plumbing: one User-Agent, request accounting, timeouts and response-size caps
// for every session, plus coordinated read-merge-write for files shared by the app and widget.

import Foundation

/// Largest response bodies FlightDesk accepts, by kind.
enum ResponseLimit {
    /// API JSON (feeds, adsbdb, OpenSky, Planespotters, the logo catalog, a receiver's aircraft.json).
    static let json = 5 << 20
    /// The plane-alert-db CSV (about 2.5 MB today).
    static let csv = 10 << 20
    /// An airline logo (PNG or SVG).
    static let logo = 1 << 20
    /// An aircraft photo.
    static let photo = 4 << 20
    /// An Airframes.io airframe record, which lists every flight it has logged (about 1 MB for a
    /// busy airliner today), or a flight with its latest 200 ACARS messages.
    static let airframes = 8 << 20
}

enum Net {
    static let userAgent = "FlightDesk/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1") (+https://github.com/BadWasabeee/flightdesk)"

    /// Ephemeral (no cookies, no credential storage) configuration with FlightDesk's User-Agent and timeouts.
    /// `resource` bounds the whole transfer, so a slow-drip server can't hold a request open.
    static func configuration(_ base: URLSessionConfiguration = .ephemeral,
                              request: TimeInterval = 8, resource: TimeInterval = 20) -> URLSessionConfiguration {
        let c = base
        c.timeoutIntervalForRequest = request
        c.timeoutIntervalForResource = resource
        c.httpAdditionalHeaders = ["User-Agent": userAgent]
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        return c
    }

    /// A session whose requests are counted in `ApiBudget` (shared with the widget).
    static func session(_ configuration: URLSessionConfiguration = configuration()) -> URLSession {
        URLSession(configuration: configuration, delegate: UsageMeter(), delegateQueue: nil)
    }
}

extension URLSession {
    /// GETs `url`, failing with `URLError(.dataLengthExceedsMaximum)` as soon as the declared or
    /// received body exceeds `limit` bytes, so an oversized response is never held in memory.
    func boundedData(from url: URL, limit: Int = ResponseLimit.json) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await self.bytes(from: url)
        if response.expectedContentLength > Int64(limit) {
            bytes.task.cancel()
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        var chunk = [UInt8]()
        chunk.reserveCapacity(16_384)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == 16_384 {
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                if data.count > limit {
                    bytes.task.cancel()
                    throw URLError(.dataLengthExceedsMaximum)
                }
            }
        }
        data.append(contentsOf: chunk)
        guard data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        return (data, response)
    }
}

/// Files in the app-group container written by both the app and the widget.
enum SharedFile {
    /// Reads `url`, passes its contents (nil when missing) to `transform`, and atomically writes the
    /// result (unless nil) — all inside a file coordinator, so a concurrent writer in the other
    /// process is serialised rather than silently overwritten.
    static func update(_ url: URL, _ transform: (Data?) -> Data?) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forMerging, error: &error) { u in
            if let out = transform(try? Data(contentsOf: u)) { try? out.write(to: u, options: .atomic) }
        }
        if let error { fdLog.error("Couldn’t update \(url.lastPathComponent, privacy: .public): \(error.localizedDescription)") }
    }
}
