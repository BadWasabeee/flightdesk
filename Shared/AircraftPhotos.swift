// Airframe photos from Planespotters.net's public photo API.
// Foundation only, so it builds in every target. Only the aircraft's ICAO hex (and, as a
// fallback, its registration) is sent; never the user's location.

import Foundation

/// A photo of a specific airframe, with the attribution Planespotters.net requires.
struct AircraftPhoto: Codable, Equatable, Sendable {
    /// The larger thumbnail (`thumbnail_large`), around 280 px tall.
    let imageURL: URL
    /// Pixel size of the image, when reported; used to reserve space before it loads.
    let width: Double?
    let height: Double?
    /// The photo's page on planespotters.net (attribution link).
    let pageURL: URL
    let photographer: String

    /// Width ÷ height, falling back to a typical 3:2 frame.
    var aspectRatio: Double {
        guard let w = width, let h = height, w > 0, h > 0 else { return 1.5 }
        return w / h
    }

    /// "© Photographer / Planespotters.net".
    var credit: String {
        photographer.isEmpty ? "© Planespotters.net" : "© \(photographer) / Planespotters.net"
    }
}

/// Looks up and caches airframe photos. Results (including "no photo") are kept in memory and
/// in a small JSON file in the App Group container, so each aircraft is queried at most about
/// once a week; images go through a dedicated on-disk URL cache.
actor AircraftPhotos {
    static let shared = AircraftPhotos()

    /// A cached lookup result; `photo == nil` records that none exists.
    struct Entry: Codable { var photo: AircraftPhoto?; var at: Date }

    /// How long a found photo is reused before asking again.
    static let hitLifetime: TimeInterval = 7 * 86_400
    /// How long a "no photo" answer is reused (new photos are uploaded all the time).
    static let missLifetime: TimeInterval = 86_400
    private static let maxEntries = 600

    private var entries: [String: Entry]?
    private var inFlight: [String: Task<AircraftPhoto?, Never>] = [:]
    private let fileURL: URL
    private let session: URLSession

    init(directory: URL = Shared.containerURL) {
        fileURL = directory.appendingPathComponent("aircraft-photos.json")
        // Same User-Agent, timeouts and request accounting as `FlightService.session`, plus an
        // on-disk URL cache: the image CDN sends long max-age headers, so repeat views work offline.
        let config = Net.configuration(.default, request: 10, resource: 20)
        config.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 40 << 20,
                                   directory: directory.appendingPathComponent("aircraft-photos", isDirectory: true))
        config.requestCachePolicy = .useProtocolCachePolicy
        session = Net.session(config)
    }

    /// The photo for the aircraft with ICAO `hex`, trying `registration` when the hex has none.
    /// Nil when there is no photo or the service can't be reached.
    func photo(hex: String, registration: String?) async -> AircraftPhoto? {
        // Non-ICAO addresses ("~…", TIS-B) don't identify an airframe.
        guard let key = AircraftID.hex(hex, allowNonICAO: false) else { return nil }
        loadIfNeeded()
        if let e = entries?[key], Self.isFresh(e) { return e.photo }
        if let task = inFlight[key] { return await task.value }

        let reg = registration?.trimmingCharacters(in: .whitespaces) ?? ""
        let task = Task { await self.fetch(key: key, registration: reg.uppercased() == key.uppercased() ? "" : reg) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// Image bytes for `photo` (at most `ResponseLimit.photo`), from the URL cache when possible.
    /// Decode with `ImageGuard.thumbnail(_:_:maxPixel:)` and `ImageGuard.photo`.
    func imageData(for photo: AircraftPhoto) async -> Data? {
        guard let (data, resp) = try? await session.boundedData(from: photo.imageURL, limit: ResponseLimit.photo),
              (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    // MARK: Lookup

    private enum Outcome { case found(AircraftPhoto), noPhoto, failed }

    private func fetch(key: String, registration: String) async -> AircraftPhoto? {
        var outcome = await query(["hex", key])
        if case .noPhoto = outcome, !registration.isEmpty {
            outcome = await query(["reg", registration])
        }
        switch outcome {
        case .found(let photo):
            store(Entry(photo: photo, at: Date()), for: key)
            return photo
        case .noPhoto:
            store(Entry(photo: nil, at: Date()), for: key)
            return nil
        case .failed:
            // Fall back to a stale result rather than nothing; don't cache the failure.
            return entries?[key]?.photo
        }
    }

    private func query(_ path: [String]) async -> Outcome {
        guard let url = RemoteURL.make("https://api.planespotters.net/pub/photos", path),
              let (data, resp) = try? await session.boundedData(from: url) else { return .failed }
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            fdLog.info("Planespotters \(path.first ?? "", privacy: .public): HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
            return .failed
        }
        do {
            return try Self.parse(data).map(Outcome.found) ?? .noPhoto
        } catch {
            return .failed
        }
    }

    /// Parses a `/pub/photos` response: the first usable photo, or nil when it lists none.
    /// Throws for a malformed response.
    static func parse(_ data: Data) throws -> AircraftPhoto? {
        struct Response: Decodable { let photos: [Photo]? }
        struct Photo: Decodable {
            struct Size: Decodable { let width: Double?; let height: Double? }
            struct Thumb: Decodable { let src: URL?; let size: Size? }
            let thumbnail_large: Thumb?
            let thumbnail: Thumb?
            let link: URL?
            let photographer: String?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.photos ?? []).lazy.compactMap { p -> AircraftPhoto? in
            guard let thumb = p.thumbnail_large ?? p.thumbnail, let src = thumb.src,
                  src.scheme == "https", let link = p.link, link.scheme == "https" else { return nil }
            return AircraftPhoto(imageURL: src, width: thumb.size?.width, height: thumb.size?.height,
                                 pageURL: link, photographer: p.photographer?.trimmingCharacters(in: .whitespaces) ?? "")
        }.first
    }

    // MARK: Cache

    static func isFresh(_ e: Entry, now: Date = Date()) -> Bool {
        now.timeIntervalSince(e.at) < (e.photo == nil ? missLifetime : hitLifetime)
    }

    private func loadIfNeeded() {
        guard entries == nil else { return }
        entries = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: fileURL))) ?? [:]
    }

    /// Saves `entry`, merged with what the other process (app or widget) wrote meanwhile.
    private func store(_ entry: Entry, for key: String) {
        loadIfNeeded()
        var all = entries ?? [:]
        all[key] = entry
        SharedFile.update(fileURL) { data in
            let disk = data.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
            all = Self.pruned(all.merging(disk) { mine, theirs in mine.at >= theirs.at ? mine : theirs })
            return try? JSONEncoder().encode(all)
        }
        entries = all
    }

    private static func pruned(_ entries: [String: Entry]) -> [String: Entry] {
        guard entries.count > maxEntries else { return entries }
        let now = Date()
        let all = entries.filter { isFresh($0.value, now: now) }
        guard all.count > maxEntries else { return all }
        return Dictionary(uniqueKeysWithValues: all.sorted { $0.value.at > $1.value.at }
            .prefix(maxEntries * 3 / 4).map { ($0.key, $0.value) })
    }
}
