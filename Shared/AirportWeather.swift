// Airport weather (METAR and TAF) from the aviationweather.gov Data API: free, no key, and only
// airport codes are sent. Foundation only, so it builds in every target; the app's flight detail
// and main-window inspector use it.

import Foundation

// MARK: - Model

/// FAA flight category, from ceiling and visibility.
enum FlightCategory: String, Codable, Equatable, Sendable, CaseIterable {
    case vfr = "VFR", mvfr = "MVFR", ifr = "IFR", lifr = "LIFR"

    /// The category for a ceiling (lowest broken, overcast or vertical-visibility layer) and a
    /// visibility in statute miles; the worse of the two decides. Nil when neither is known.
    /// LIFR: ceiling < 500 ft or visibility < 1 SM. IFR: 500 to < 1,000 ft or 1 to < 3 SM.
    /// MVFR: 1,000 to 3,000 ft or 3 to 5 SM. VFR: above both.
    static func from(ceilingFt: Int?, visibilitySM: Double?) -> FlightCategory? {
        guard ceilingFt != nil || visibilitySM != nil else { return nil }
        func byCeiling(_ c: Int) -> FlightCategory {
            c < 500 ? .lifr : c < 1_000 ? .ifr : c <= 3_000 ? .mvfr : .vfr
        }
        func byVisibility(_ v: Double) -> FlightCategory {
            v < 1 ? .lifr : v < 3 ? .ifr : v <= 5 ? .mvfr : .vfr
        }
        let c = ceilingFt.map(byCeiling) ?? .vfr
        let v = visibilitySM.map(byVisibility) ?? .vfr
        return max(c, v)
    }

    /// Worse categories sort higher.
    var severity: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

extension FlightCategory: Comparable {
    static func < (a: Self, b: Self) -> Bool { a.severity < b.severity }
}

/// Surface wind. Directions are degrees true, as METARs report them.
struct SurfaceWind: Codable, Equatable, Sendable {
    /// Nil when the direction is variable ("VRB").
    var directionDeg: Int?
    var speedKt: Int
    var gustKt: Int?
    /// The direction varies between these two headings ("360V070"), when reported.
    var variableFromDeg: Int?
    var variableToDeg: Int?

    var isCalm: Bool { speedKt == 0 && (gustKt ?? 0) == 0 }
    var isVariable: Bool { directionDeg == nil || variableFromDeg != nil }
}

/// Prevailing visibility in statute miles; `orMore` for "10+" (or "P6SM").
struct WeatherVisibility: Codable, Equatable, Sendable {
    var statuteMiles: Double
    var orMore: Bool = false

    var kilometres: Double { statuteMiles * 1.609344 }
}

/// One cloud layer. `cover` is FEW, SCT, BKN, OVC or OVX (sky obscured, base = vertical visibility).
struct CloudLayer: Codable, Equatable, Sendable {
    var cover: String
    var baseFt: Int?

    var isCeiling: Bool { ["BKN", "OVC", "OVX", "VV"].contains(cover) }
}

/// A decoded METAR.
struct Metar: Codable, Equatable, Sendable {
    var station: String
    var raw: String
    var observed: Date
    var wind: SurfaceWind?
    var visibility: WeatherVisibility?
    var clouds: [CloudLayer]
    var temperatureC: Double?
    var dewpointC: Double?
    /// Altimeter setting in hPa (exact for Q-groups, converted for A-groups).
    var altimeterHPa: Double?
    /// Altimeter setting in inches of mercury (exact for A-groups, converted for Q-groups).
    var altimeterInHg: Double?
    /// From the API, or computed from ceiling and visibility when it doesn't supply one.
    var category: FlightCategory?

    /// Base of the lowest broken, overcast or obscured layer.
    var ceilingFt: Int? { clouds.filter(\.isCeiling).compactMap(\.baseFt).min() }
    /// The layer that forms the ceiling.
    var ceilingLayer: CloudLayer? {
        clouds.filter { $0.isCeiling && $0.baseFt != nil }.min { ($0.baseFt ?? 0) < ($1.baseFt ?? 0) }
    }
}

/// A terminal aerodrome forecast.
struct Taf: Codable, Equatable, Sendable {
    var station: String
    var raw: String
    var issued: Date?
    var validFrom: Date?
    var validTo: Date?
}

// MARK: - Station codes

enum WeatherStation {
    /// The ICAO station id for an airport shown with its IATA (3-letter) or ICAO (4-letter) code.
    static func icao(for airport: Airport) -> String? { icao(code: airport.code) }

    static func icao(code raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespaces).uppercased()
        switch code.count {
        case 4: return AirportCode.icao(code)
        case 3: return AirportDB.icao(iata: code).flatMap(AirportCode.icao)
        default: return nil
        }
    }
}

// MARK: - Decoding (aviationweather.gov /api/data, format=json)

enum WeatherDecoder {
    /// A JSON value that may be a number or a string ("VRB", "10+", "6+").
    private enum Flexible: Decodable {
        case number(Double), string(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { self = .number(d); return }
            self = .string(try c.decode(String.self))
        }
        var number: Double? {
            switch self {
            case .number(let d): return d
            case .string(let s): return Double(s)
            }
        }
    }

    /// Decodes an element without failing the enclosing array.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private struct MetarRecord: Decodable {
        struct Cloud: Decodable { let cover: String?; let base: Double? }
        let icaoId: String
        let obsTime: Double?
        let rawOb: String?
        let temp: Double?
        let dewp: Double?
        let wdir: Flexible?
        let wspd: Double?
        let wgst: Double?
        let visib: Flexible?
        let altim: Double?
        let clouds: [Cloud]?
        let fltCat: String?
    }

    private struct TafRecord: Decodable {
        let icaoId: String
        let rawTAF: String?
        let issueTime: String?
        let validTimeFrom: Double?
        let validTimeTo: Double?
    }

    /// METARs in a response (an empty body, as for HTTP 204, means none). Records without a station,
    /// raw text or observation time are skipped; the newest report per station wins.
    static func metars(from data: Data) throws -> [Metar] {
        guard !data.isEmpty else { return [] }
        let records = try JSONDecoder().decode([Lossy<MetarRecord>].self, from: data).compactMap(\.value)
        var newest: [String: Metar] = [:]
        for r in records {
            guard let m = metar(r) else { continue }
            if let old = newest[m.station], old.observed >= m.observed { continue }
            newest[m.station] = m
        }
        return newest.values.sorted { $0.station < $1.station }
    }

    /// TAFs in a response; the newest per station wins.
    static func tafs(from data: Data) throws -> [Taf] {
        guard !data.isEmpty else { return [] }
        let records = try JSONDecoder().decode([Lossy<TafRecord>].self, from: data).compactMap(\.value)
        var newest: [String: Taf] = [:]
        for r in records {
            guard let station = AirportCode.icao(r.icaoId), let raw = r.rawTAF?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            let t = Taf(station: station, raw: String(raw.prefix(4_000)), issued: r.issueTime.flatMap(isoDate),
                        validFrom: r.validTimeFrom.map(Date.init(timeIntervalSince1970:)),
                        validTo: r.validTimeTo.map(Date.init(timeIntervalSince1970:)))
            if let old = newest[station], (old.issued ?? .distantPast) >= (t.issued ?? .distantPast) { continue }
            newest[station] = t
        }
        return newest.values.sorted { $0.station < $1.station }
    }

    private static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private static func metar(_ r: MetarRecord) -> Metar? {
        guard let station = AirportCode.icao(r.icaoId), let t = r.obsTime,
              let raw = r.rawOb?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let groups = raw.split(separator: " ").map(String.init)

        var wind: SurfaceWind?
        if let speed = r.wspd, speed >= 0, speed < 300 {
            let dir: Int?
            switch r.wdir {
            case .number(let d)?: dir = (0...360).contains(d) ? Int(d) % 360 : nil
            default: dir = nil   // "VRB" or missing
            }
            var w = SurfaceWind(directionDeg: dir, speedKt: Int(speed.rounded()),
                                gustKt: r.wgst.flatMap { $0 > 0 && $0 < 300 ? Int($0.rounded()) : nil })
            if let range = variableRange(groups) { w.variableFromDeg = range.0; w.variableToDeg = range.1 }
            wind = w
        }

        let clouds = (r.clouds ?? []).compactMap { c -> CloudLayer? in
            guard let cover = c.cover?.uppercased(), ["FEW", "SCT", "BKN", "OVC", "OVX", "VV"].contains(cover) else { return nil }
            return CloudLayer(cover: cover, baseFt: c.base.flatMap { $0 >= 0 && $0 < 100_000 ? Int($0) : nil })
        }

        var hPa = r.altim.flatMap { (850...1_100).contains($0) ? $0 : nil }
        var inHg = hPa.map { $0 / 33.8639 }
        if let exact = altimeterGroup(groups) {
            switch exact {
            case .inHg(let v): inHg = v; hPa = v * 33.8639
            case .hPa(let v): hPa = v; inHg = v / 33.8639
            }
        }

        var m = Metar(station: station, raw: String(raw.prefix(1_000)), observed: Date(timeIntervalSince1970: t),
                      wind: wind, visibility: r.visib.flatMap(visibility), clouds: clouds,
                      temperatureC: r.temp, dewpointC: r.dewp, altimeterHPa: hPa, altimeterInHg: inHg, category: nil)
        m.category = r.fltCat.flatMap { FlightCategory(rawValue: $0.uppercased()) }
            ?? FlightCategory.from(ceilingFt: m.ceilingFt, visibilitySM: m.visibility?.statuteMiles)
        return m
    }

    /// "10+", "6+", "P6", "1/2", "1 1/2", "M1/4" or a number, in statute miles.
    private static func visibility(_ v: Flexible) -> WeatherVisibility? {
        switch v {
        case .number(let d): return d >= 0 ? WeatherVisibility(statuteMiles: d) : nil
        case .string(let s): return visibility(text: s)
        }
    }

    static func visibility(text raw: String) -> WeatherVisibility? {
        var s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        var orMore = false
        if s.hasSuffix("+") { orMore = true; s.removeLast() }
        if s.hasPrefix("P") { orMore = true; s.removeFirst() }
        if s.hasPrefix("M") { s.removeFirst() }
        if s.hasSuffix("SM") { s.removeLast(2) }
        var total = 0.0
        let parts = s.split(separator: " ")
        guard !parts.isEmpty else { return nil }
        for p in parts {
            let f = p.split(separator: "/")
            if f.count == 2, let n = Double(f[0]), let d = Double(f[1]), d > 0 {
                total += n / d
            } else if f.count == 1, let n = Double(f[0]) {
                total += n
            } else {
                return nil
            }
        }
        return total >= 0 ? WeatherVisibility(statuteMiles: total, orMore: orMore) : nil
    }

    private enum Altimeter { case inHg(Double), hPa(Double) }

    /// The first "A2965" or "Q1020" group before any remarks or trend.
    private static func altimeterGroup(_ groups: [String]) -> Altimeter? {
        for g in groups {
            if g == "RMK" || g == "TEMPO" || g == "BECMG" || g == "NOSIG" { break }
            guard g.count == 5, let v = Int(g.dropFirst()) else { continue }
            if g.hasPrefix("A"), (2_500...3_200).contains(v) { return .inHg(Double(v) / 100) }
            if g.hasPrefix("Q"), (850...1_100).contains(v) { return .hPa(Double(v)) }
        }
        return nil
    }

    /// A "dddVddd" variable wind direction group.
    private static func variableRange(_ groups: [String]) -> (Int, Int)? {
        for g in groups.prefix(8) where g.count == 7 {
            let c = Array(g)
            guard c[3] == "V", let a = Int(String(c[0..<3])), let b = Int(String(c[4..<7])),
                  (0...360).contains(a), (0...360).contains(b) else { continue }
            return (a % 360, b % 360)
        }
        return nil
    }
}

// MARK: - Wind components

/// Wind resolved along and across a runway.
struct WindComponents: Equatable, Sendable {
    /// Along the runway: positive is a headwind, negative a tailwind (knots).
    var headwindKt: Double
    /// Across the runway: positive from the right, negative from the left (knots).
    var crosswindKt: Double
    /// The crosswind in the gusts, when gusts are reported.
    var gustCrosswindKt: Double?

    /// Components of `wind` for a runway with `runwayHeading` (degrees true). Nil when the
    /// direction is variable ("VRB"); calm wind gives zero components.
    static func of(_ wind: SurfaceWind, runwayHeading: Double) -> WindComponents? {
        if wind.isCalm { return WindComponents(headwindKt: 0, crosswindKt: 0) }
        guard let dir = wind.directionDeg else { return nil }
        let angle = (Double(dir) - runwayHeading) * .pi / 180
        func clean(_ v: Double) -> Double { abs(v) < 1e-9 ? 0 : v }
        let speed = Double(wind.speedKt)
        return WindComponents(headwindKt: clean(speed * cos(angle)), crosswindKt: clean(speed * sin(angle)),
                              gustCrosswindKt: wind.gustKt.map { clean(Double($0) * sin(angle)) })
    }
}

// MARK: - Formatting (pure, unit-tested)

enum WeatherFormat {
    private static func number(_ v: Double, _ locale: Locale) -> String {
        Int(v.rounded()).formatted(.number.locale(locale))
    }

    private static func speed(_ kt: Int, units: UnitSystem) -> Int {
        units == .metric ? Int((Double(kt) * 1.852).rounded()) : kt
    }

    /// "320° 11G18 kt", "VRB 4 kt", "040° 3 kt (360°–070°)", "Calm"; km/h for metric.
    static func wind(_ w: SurfaceWind, units: UnitSystem) -> String {
        if w.isCalm { return "Calm" }
        let unit = units == .metric ? "km/h" : "kt"
        let dir = w.directionDeg.map { String(format: "%03d°", $0 == 0 ? 360 : $0) } ?? "VRB"
        var s = "\(dir) \(speed(w.speedKt, units: units))"
        if let g = w.gustKt { s += "G\(speed(g, units: units))" }
        s += " \(unit)"
        if let a = w.variableFromDeg, let b = w.variableToDeg {
            s += String(format: " (%03d°–%03d°)", a == 0 ? 360 : a, b == 0 ? 360 : b)
        }
        return s
    }

    /// "10+ SM", "1/2 SM", "2 1/2 SM"; metric "10+ km", "6 km", "800 m".
    static func visibility(_ v: WeatherVisibility, units: UnitSystem, locale: Locale = .autoupdatingCurrent) -> String {
        if units == .metric {
            // "6+ SM" is how the API reports 9999 (10 km or more).
            if v.orMore, v.statuteMiles >= 6 { return "10+ km" }
            let km = v.kilometres
            if km < 5 { return "\(number((km * 10).rounded() * 100, locale)) m" }
            return "\(number(km, locale))\(v.orMore ? "+" : "") km"
        }
        return "\(statuteMiles(v.statuteMiles))\(v.orMore ? "+" : "") SM"
    }

    /// Whole miles with common fractions: "3", "1/2", "1 3/4".
    static func statuteMiles(_ sm: Double) -> String {
        let quarters = Int((sm * 4).rounded())
        if sm >= 3 || quarters % 4 == 0 { return String(Int(sm.rounded())) }
        let whole = quarters / 4
        let fraction = ["", "1/4", "1/2", "3/4"][quarters % 4]
        return whole == 0 ? fraction : "\(whole) \(fraction)"
    }

    /// "BKN 1,200 ft", "VV 300 ft", "None" (no ceiling); metres for metric.
    static func ceiling(_ m: Metar, units: UnitSystem, locale: Locale = .autoupdatingCurrent) -> String {
        guard let layer = m.ceilingLayer, let base = layer.baseFt else { return "None" }
        let cover = layer.cover == "OVX" ? "VV" : layer.cover
        if units == .metric { return "\(cover) \(number(Double(base) * 0.3048, locale)) m" }
        return "\(cover) \(base.formatted(.number.locale(locale))) ft"
    }

    /// "3° / −1° C" (METARs report Celsius in every country).
    static func temperature(_ m: Metar) -> String? {
        guard let t = m.temperatureC else { return nil }
        func deg(_ v: Double) -> String {
            let n = Int(v.rounded())
            return n < 0 ? "−\(-n)°" : "\(n)°"
        }
        return m.dewpointC.map { "\(deg(t)) / \(deg($0)) C" } ?? "\(deg(t)) C"
    }

    /// Aviation units: "29.65 inHg · 1004 hPa"; metric: "1004 hPa".
    static func altimeter(_ m: Metar, units: UnitSystem) -> String? {
        guard let hPa = m.altimeterHPa else { return nil }
        let hpa = "\(Int(hPa.rounded())) hPa"
        guard units == .imperial, let inHg = m.altimeterInHg else { return hpa }
        return String(format: "%.2f inHg", inHg) + " · " + hpa
    }

    /// "just now", "12 m ago", "1 h 5 m ago".
    static func age(_ observed: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(observed)
        return s < 60 ? "just now" : "\(FlightMath.durationText(s)) ago"
    }

    /// "Headwind 8 kt · Crosswind 5 kt from the right (gusts 9)"; "Tailwind …" when the wind is behind.
    static func components(_ c: WindComponents, units: UnitSystem) -> String {
        let unit = units == .metric ? "km/h" : "kt"
        func v(_ kt: Double) -> Int { units == .metric ? Int((abs(kt) * 1.852).rounded()) : Int(abs(kt).rounded()) }
        let along = c.headwindKt < 0 && v(c.headwindKt) > 0 ? "Tailwind \(v(c.headwindKt)) \(unit)" : "Headwind \(v(c.headwindKt)) \(unit)"
        var across = "crosswind \(v(c.crosswindKt)) \(unit)"
        if v(c.crosswindKt) > 0 { across += c.crosswindKt > 0 ? " from the right" : " from the left" }
        if let g = c.gustCrosswindKt, v(g) > v(c.crosswindKt) { across += " (gusts \(v(g)))" }
        return "\(along) · \(across)"
    }

    /// A TAF split onto lines at each change group (FM, TEMPO, BECMG, PROB).
    static func tafLines(_ raw: String) -> [String] {
        var lines: [[Substring]] = [[]]
        let words = raw.split(whereSeparator: \.isWhitespace)
        for (i, w) in words.enumerated() {
            let startsGroup = w.hasPrefix("FM") && w.count == 8 && w.dropFirst(2).allSatisfy(\.isNumber)
                || w == "TEMPO" || w == "BECMG"
                || (w.hasPrefix("PROB") && w.count == 6)
            // "PROB30 TEMPO" stays on one line.
            let afterProb = i > 0 && words[i - 1].hasPrefix("PROB")
            if startsGroup, !afterProb, !(lines.last?.isEmpty ?? true) { lines.append([]) }
            lines[lines.count - 1].append(w)
        }
        return lines.filter { !$0.isEmpty }.map { $0.joined(separator: " ") }
    }
}

// MARK: - Service and cache

/// Fetches and caches METARs (about 10 minutes) and TAFs (about 30), in memory and in a small JSON
/// file in the App Group container. Concurrent requests for the same airport share one network
/// request, and the airports a caller asks for are batched into one request per product.
///
/// aviationweather.gov asks clients to stay under 100 requests a minute; FlightDesk caps itself at
/// `ApiService.aviationWeather.minuteLimit` per process, backs off after a failure, and stops
/// whenever `ApiBudget` has paused the service (after HTTP 429).
actor WeatherService {
    static let shared = WeatherService()

    enum Product: String, Sendable, CaseIterable {
        case metar, taf

        /// How long a fetched result is reused before asking again.
        var lifetime: TimeInterval { self == .metar ? 10 * 60 : 30 * 60 }
        /// After this, a cached result is too old to show even when a refresh fails.
        var maxAge: TimeInterval { self == .metar ? 3 * 3_600 : 12 * 3_600 }
    }

    /// Fetches the raw response for a batch of station ids (nil or empty data: no reports).
    typealias Fetcher = @Sendable (Product, [String]) async throws -> Data?

    /// A cached answer for one station; `value == nil` records that it has no current report.
    struct Entry<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
        var value: Value?
        var at: Date
    }

    struct Store: Codable, Equatable {
        var metars: [String: Entry<Metar>] = [:]
        var tafs: [String: Entry<Taf>] = [:]
    }

    static let batchLimit = 20
    /// Wait this long after a failed request before trying the same product again.
    static let failureBackoff: TimeInterval = 60

    private var store: Store?
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var recentRequests: [Date] = []
    private var lastFailure: [Product: Date] = [:]
    private let fileURL: URL?
    private let fetcher: Fetcher
    private let now: @Sendable () -> Date
    private let minuteLimit: Int

    /// - Parameters:
    ///   - directory: where the disk cache lives; nil keeps it in memory only.
    ///   - fetcher: replaces the network (tests).
    ///   - now: the clock (tests).
    init(directory: URL? = Shared.containerURL, fetcher: Fetcher? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         minuteLimit: Int = ApiService.aviationWeather.minuteLimit ?? 20) {
        fileURL = directory?.appendingPathComponent("airport-weather.json")
        self.fetcher = fetcher ?? WeatherService.download
        self.now = now
        self.minuteLimit = minuteLimit
    }

    /// The latest METAR for each station id (ICAO), from the cache when fresh. Stations without a
    /// report (or not reachable and never cached) are absent.
    func metars(_ ids: [String]) async -> [String: Metar] {
        await load(.metar, ids)
        return values(ids, in: store?.metars ?? [:], maxAge: Product.metar.maxAge)
    }

    /// The current TAF for each station id (ICAO), from the cache when fresh.
    func tafs(_ ids: [String]) async -> [String: Taf] {
        await load(.taf, ids)
        return values(ids, in: store?.tafs ?? [:], maxAge: Product.taf.maxAge)
    }

    /// Whether a cached entry fetched at `at` is still fresh for `product`.
    static func isFresh(_ at: Date, product: Product, now: Date) -> Bool {
        now.timeIntervalSince(at) < product.lifetime && now >= at.addingTimeInterval(-60)
    }

    // MARK: Internals

    private func values<V>(_ ids: [String], in entries: [String: Entry<V>], maxAge: TimeInterval) -> [String: V] {
        let t = now()
        var out: [String: V] = [:]
        for id in Self.sanitized(ids) {
            if let e = entries[id], let v = e.value, t.timeIntervalSince(e.at) < maxAge { out[id] = v }
        }
        return out
    }

    static func sanitized(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap(AirportCode.icao).filter { seen.insert($0).inserted }
    }

    private func fetchedAt(_ product: Product, _ id: String) -> Date? {
        switch product {
        case .metar: return store?.metars[id]?.at
        case .taf: return store?.tafs[id]?.at
        }
    }

    /// Makes sure every id has a fresh entry, joining requests already in flight and batching the rest.
    private func load(_ product: Product, _ raw: [String]) async {
        loadIfNeeded()
        let t = now()
        var waits: [Task<Void, Never>] = []
        var missing: [String] = []
        for id in Self.sanitized(raw) {
            if let at = fetchedAt(product, id), Self.isFresh(at, product: product, now: t) { continue }
            if let task = inFlight[key(product, id)] {
                if !waits.contains(task) { waits.append(task) }
            } else {
                missing.append(id)
            }
        }
        var started: [(Task<Void, Never>, [String])] = []
        for batch in stride(from: 0, to: missing.count, by: Self.batchLimit).map({ Array(missing[$0..<min($0 + Self.batchLimit, missing.count)]) }) {
            guard mayRequest(product, now: t) else { break }
            recentRequests.append(t)
            let task = Task { await self.fetch(product, batch) }
            for id in batch { inFlight[key(product, id)] = task }
            started.append((task, batch))
            waits.append(task)
        }
        for task in waits { await task.value }
        for (task, batch) in started {
            for id in batch where inFlight[key(product, id)] == task { inFlight[key(product, id)] = nil }
        }
    }

    private func key(_ product: Product, _ id: String) -> String { "\(product.rawValue):\(id)" }

    /// Within the per-minute cap, not backing off after a failure, and not paused by `ApiBudget`.
    private func mayRequest(_ product: Product, now t: Date) -> Bool {
        recentRequests.removeAll { t.timeIntervalSince($0) >= 60 }
        guard recentRequests.count < minuteLimit else { return false }
        if let failed = lastFailure[product], t.timeIntervalSince(failed) < Self.failureBackoff { return false }
        return ApiBudget.isAvailable(.aviationWeather)
    }

    private func fetch(_ product: Product, _ ids: [String]) async {
        let data: Data?
        do {
            data = try await fetcher(product, ids)
        } catch {
            fdLog.info("Weather \(product.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            lastFailure[product] = now()
            return
        }
        let t = now()
        do {
            switch product {
            case .metar:
                let found = Dictionary(try WeatherDecoder.metars(from: data ?? Data()).map { ($0.station, $0) }, uniquingKeysWith: { a, _ in a })
                for id in ids { store?.metars[id] = Entry(value: found[id], at: t) }
            case .taf:
                let found = Dictionary(try WeatherDecoder.tafs(from: data ?? Data()).map { ($0.station, $0) }, uniquingKeysWith: { a, _ in a })
                for id in ids { store?.tafs[id] = Entry(value: found[id], at: t) }
            }
        } catch {
            fdLog.info("Weather \(product.rawValue, privacy: .public): unreadable response")
            lastFailure[product] = t
            return
        }
        lastFailure[product] = nil
        save()
    }

    /// GETs `/api/data/{metar|taf}?ids=…&format=json` (ids already validated as ICAO codes).
    private static let download: Fetcher = { product, ids in
        let base = product == .metar ? "https://aviationweather.gov/api/data/metar" : "https://aviationweather.gov/api/data/taf"
        guard let url = RemoteURL.make(base, query: [("ids", ids.joined(separator: ",")), ("format", "json")]) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await FlightService.session.boundedData(from: url, limit: ResponseLimit.json)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return data
        case 204: return nil   // no reports for these stations
        case let status: throw URLError(.badServerResponse, userInfo: ["status": status])
        }
    }

    // MARK: Disk cache

    private func loadIfNeeded() {
        guard store == nil else { return }
        store = fileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store()
    }

    /// Writes the cache, merged (newest entry wins) with what the other process wrote meanwhile.
    private func save() {
        guard let fileURL, let mine = store else { return }
        var merged = mine
        let t = now()
        SharedFile.update(fileURL) { data in
            let disk = data.flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store()
            merged = Self.pruned(Self.merge(mine, disk), now: t)
            return try? JSONEncoder().encode(merged)
        }
        store = merged
    }

    static func merge(_ a: Store, _ b: Store) -> Store {
        Store(metars: a.metars.merging(b.metars) { $0.at >= $1.at ? $0 : $1 },
              tafs: a.tafs.merging(b.tafs) { $0.at >= $1.at ? $0 : $1 })
    }

    /// Drops entries too old to show.
    static func pruned(_ s: Store, now: Date) -> Store {
        Store(metars: s.metars.filter { now.timeIntervalSince($0.value.at) < Product.metar.maxAge },
              tafs: s.tafs.filter { now.timeIntervalSince($0.value.at) < Product.taf.maxAge })
    }
}

// MARK: - Weather for a flight's airports

/// The latest reports for one airport of a flight.
struct AirportConditions: Equatable, Sendable {
    var airport: Airport
    /// ICAO station id the reports are for.
    var station: String
    var metar: Metar?
    var taf: Taf?

    /// An entry without reports yet, or nil when the airport's ICAO station id isn't known.
    init?(airport: Airport) {
        guard let station = WeatherStation.icao(for: airport) else { return nil }
        self.init(airport: airport, station: station)
    }

    init(airport: Airport, station: String, metar: Metar? = nil, taf: Taf? = nil) {
        self.airport = airport
        self.station = station
        self.metar = metar
        self.taf = taf
    }

    /// Whether `other` is this airport (by code or ICAO station).
    func matches(_ other: Airport) -> Bool {
        other.code == airport.code || WeatherStation.icao(for: other) == station
    }

    /// Wind components for the runway end `ident`, when the runway and a directional wind are known.
    func components(runway ident: String,
                    lookup: (_ ident: String, _ code: String) -> (end: RunwayEnd, far: RunwayEnd)? = RunwayDB.runwayEnd) -> WindComponents? {
        guard let wind = metar?.wind,
              let end = lookup(ident, airport.code) ?? lookup(ident, station) else { return nil }
        return WindComponents.of(wind, runwayHeading: end.end.heading)
    }

    /// The reported altimeter setting (hPa) at the nearest of `airports` within `nm` of `position`:
    /// a stand-in for the aircraft's own QNH in the approach analysis.
    static func altimeterHPa(near position: GeoPoint, in airports: [AirportConditions], within nm: Double = 60) -> Double? {
        airports.compactMap { c -> (Double, Double)? in
            guard let hPa = c.metar?.altimeterHPa else { return nil }
            let d = FlightService.gcDistance(position.lat, position.lon, c.airport.lat, c.airport.lon)
            return d <= nm ? (d, hPa) : nil
        }.min { $0.0 < $1.0 }?.1
    }
}
