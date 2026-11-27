// The spotting log: every airframe the main app has seen near the user, kept on this Mac only.
// Pure model, merge rules, stats, filtering, persistence and CSV export, so the tests can cover
// them; the app's recorder (App/SpottingLogStore.swift) feeds it. The widget never records.

import Foundation

/// One airframe in the log, keyed by its ICAO hex.
struct LogEntry: Codable, Equatable, Identifiable {
    /// Lowercase ICAO 24-bit address.
    let hex: String
    var registration = ""
    var typeCode = ""
    /// Airline or owner, as the feed or route lookup named it.
    var operatorName = ""
    /// ICAO airline designator from an airline-style callsign (for the logo).
    var airlineICAO: String?
    /// IATA airline code from a resolved route (logo fallback).
    var airlineIATA: String?
    /// plane-alert-db `#CMPG` group (Mil, Gov, Pol, Civ) when the list was loaded at the time.
    var alertGroup: String?
    var firstSeen: Date
    var lastSeen: Date
    /// Separate visits: a sighting more than `SpottingLog.newSightingGap` after the last one counts again.
    var sightings = 1
    /// Callsigns flown while seen, most recent last, at most `SpottingLog.callsignLimit`.
    var callsigns: [String] = []
    /// Nearest distance from the user, in nautical miles, and when.
    var closestNM: Double
    var closestAt: Date
    /// Highest barometric altitude seen, in feet.
    var maxAltitude: Int
    /// Routes seen ("ORD-DEN"), most recent last, at most `SpottingLog.routeLimit`.
    var routes: [String] = []

    var id: String { hex }

    /// Who flew it, for display and sorting.
    var displayOperator: String { operatorName.isEmpty ? "Unknown operator" : operatorName }
    /// The registration, else the hex.
    var displayName: String { registration.isEmpty ? hex.uppercased() : registration }
}

/// Which part of the log to show.
enum LogPeriod: String, CaseIterable, Identifiable {
    case today, week, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: "Today"
        case .week: "This Week"
        case .all: "All"
        }
    }
}

/// Logbook ordering.
enum LogSort: String, CaseIterable, Identifiable {
    case lastSeen, firstSeen, registration, type, operatorName, sightings, closest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lastSeen: "Last Seen"
        case .firstSeen: "First Seen"
        case .registration: "Registration"
        case .type: "Type"
        case .operatorName: "Operator"
        case .sightings: "Sightings"
        case .closest: "Closest Pass"
        }
    }
}

/// What the logbook list shows.
struct LogFilter: Equatable {
    var period = LogPeriod.all
    var wideBodiesOnly = false
    var militaryOnly = false
    var query = ""

    /// True when anything narrows "everything".
    var isActive: Bool { period != .all || wideBodiesOnly || militaryOnly || !query.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Totals for the logbook header.
struct LogStats: Equatable {
    var aircraft = 0
    var types = 0
    var airlines = 0
    var today = 0
    /// Types seen on exactly one airframe, most recently seen first.
    var rarestTypes: [String] = []
}

/// The log itself: a value type with O(1) work per observed flight.
struct SpottingLog: Equatable {
    /// A gap longer than this between two observations starts a new sighting.
    static let newSightingGap: TimeInterval = 30 * 60
    static let callsignLimit = 8
    static let routeLimit = 12
    /// At most this many airframes are kept; past it the least recently seen are dropped down to `compactTarget`.
    static let capacity = 20_000
    static let compactTarget = 18_000

    private(set) var entries: [String: LogEntry] = [:]

    init(entries: [LogEntry] = []) {
        for e in entries { self.entries[e.hex] = e }
    }

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    subscript(hex: String) -> LogEntry? { entries[hex.lowercased()] }
    /// Every distinct (uppercase) type code in the log.
    var typeCodes: Set<String> { Set(entries.values.lazy.map(\.typeCode).filter { !$0.isEmpty }) }

    mutating func removeAll() { entries.removeAll() }

    // MARK: Recording

    /// What changed in one `record` call, so the recorder can decide when to publish.
    struct Change: Equatable {
        /// Airframes added for the first time.
        var added: [String] = []
        /// True when a sighting count went up (a returning aircraft).
        var newSighting = false
        /// True when anything at all changed.
        var any = false
    }

    /// Merges one batch of observed flights at `now`. `group` looks up an airframe's plane-alert-db
    /// group when that list is loaded. Linear in the batch size (amortized; compaction is rare).
    @discardableResult
    mutating func record(_ flights: [Flight], at now: Date, group: (String) -> String? = { _ in nil }) -> Change {
        var change = Change()
        for f in flights {
            guard let hex = AircraftID.hex(f.id, allowNonICAO: false) else { continue }
            if entries[hex] != nil {
                if entries[hex]!.merge(f, at: now, group: group(hex)) { change.newSighting = true }
            } else {
                entries[hex] = LogEntry(f, hex: hex, at: now, group: group(hex))
                change.added.append(hex)
            }
            change.any = true
        }
        if entries.count > Self.capacity { compact(to: Self.compactTarget) }
        return change
    }

    /// Merges entries recorded elsewhere (the FlightDesk server's log): new airframes are added,
    /// known ones combined with `LogEntry.absorb`. Purely additive: nothing local is removed.
    @discardableResult
    mutating func absorb(_ remote: [LogEntry]) -> Change {
        var change = Change()
        for r in remote {
            guard let hex = AircraftID.hex(r.hex, allowNonICAO: false) else { continue }
            if entries[hex] != nil {
                let before = entries[hex]
                entries[hex]!.absorb(r)
                if entries[hex] != before { change.any = true }
            } else {
                entries[hex] = r
                change.added.append(hex)
                change.any = true
            }
        }
        if entries.count > Self.capacity { compact(to: Self.compactTarget) }
        return change
    }

    /// Keeps the `limit` most recently seen airframes.
    mutating func compact(to limit: Int) {
        guard entries.count > limit else { return }
        let keep = entries.values.sorted { $0.lastSeen > $1.lastSeen }.prefix(limit)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.hex, $0) })
    }

    // MARK: Stats and filtering

    func stats(now: Date, calendar: Calendar = .current) -> LogStats {
        let startOfDay = calendar.startOfDay(for: now)
        var s = LogStats(aircraft: entries.count)
        var typeCounts: [String: (count: Int, last: Date)] = [:]
        var airlines = Set<String>()
        for e in entries.values {
            if e.lastSeen >= startOfDay { s.today += 1 }
            if let a = e.airlineICAO ?? e.airlineIATA { airlines.insert(a) }
            guard !e.typeCode.isEmpty else { continue }
            let t = typeCounts[e.typeCode]
            typeCounts[e.typeCode] = ((t?.count ?? 0) + 1, max(t?.last ?? .distantPast, e.lastSeen))
        }
        s.types = typeCounts.count
        s.airlines = airlines.count
        s.rarestTypes = typeCounts.filter { $0.value.count == 1 }
            .sorted { $0.value.last != $1.value.last ? $0.value.last > $1.value.last : $0.key < $1.key }
            .map(\.key)
        return s
    }

    /// Entries passing `filter`, in `sort` order. `group` supplies plane-alert-db groups for
    /// airframes recorded before the list was loaded.
    func entries(matching filter: LogFilter, sort: LogSort, now: Date, calendar: Calendar = .current,
                 group: (String) -> String? = { _ in nil }) -> [LogEntry] {
        let since: Date? = switch filter.period {
        case .today: calendar.startOfDay(for: now)
        case .week: calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now.addingTimeInterval(-7 * 86_400)
        case .all: nil
        }
        let q = filter.query.trimmingCharacters(in: .whitespaces)
        let list = entries.values.filter { e in
            if let since, e.lastSeen < since { return false }
            if filter.wideBodiesOnly, AircraftClass(typeCode: e.typeCode) != .wideBody { return false }
            if filter.militaryOnly, (e.alertGroup ?? group(e.hex)) != "Mil" { return false }
            return q.isEmpty || Self.matches(e, query: q)
        }
        return Self.sorted(list, by: sort)
    }

    static func matches(_ e: LogEntry, query: String) -> Bool {
        let fields = [e.hex, e.registration, e.typeCode, e.operatorName, e.airlineICAO ?? "", e.airlineIATA ?? ""]
            + e.callsigns + e.routes
        return fields.contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    static func sorted(_ list: [LogEntry], by sort: LogSort) -> [LogEntry] {
        func text(_ a: String, _ b: String, _ x: LogEntry, _ y: LogEntry) -> Bool {
            // Blanks last; ties by most recent.
            if a.isEmpty != b.isEmpty { return !a.isEmpty }
            let r = a.localizedStandardCompare(b)
            return r == .orderedSame ? x.lastSeen > y.lastSeen : r == .orderedAscending
        }
        return list.sorted { x, y in
            switch sort {
            case .lastSeen: return x.lastSeen != y.lastSeen ? x.lastSeen > y.lastSeen : x.hex < y.hex
            case .firstSeen: return x.firstSeen != y.firstSeen ? x.firstSeen > y.firstSeen : x.hex < y.hex
            case .registration: return text(x.registration, y.registration, x, y)
            case .type: return text(x.typeCode, y.typeCode, x, y)
            case .operatorName: return text(x.operatorName, y.operatorName, x, y)
            case .sightings: return x.sightings != y.sightings ? x.sightings > y.sightings : x.lastSeen > y.lastSeen
            case .closest: return x.closestNM != y.closestNM ? x.closestNM < y.closestNM : x.lastSeen > y.lastSeen
            }
        }
    }

    // MARK: Persistence

    private struct File: Codable {
        var version: Int
        var entries: [LogEntry]
    }

    static let fileVersion = 1

    /// The log as JSON (Unix-time dates).
    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        return try enc.encode(File(version: Self.fileVersion, entries: Array(entries.values)))
    }

    init(data: Data) throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let file = try dec.decode(File.self, from: data)
        self.init(entries: file.entries)
    }

    /// Writes atomically to `url`, creating its folder.
    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: [.atomic])
    }

    /// Reads `url`: an empty log when there is no file. A file that can't be read is moved aside
    /// (to `<name>.corrupt`) so the next save doesn't overwrite what might be recoverable.
    static func load(from url: URL) -> SpottingLog {
        guard let data = try? Data(contentsOf: url) else { return SpottingLog() }
        do {
            return try SpottingLog(data: data)
        } catch {
            fdLog.error("Spotting log unreadable; set aside: \(error.localizedDescription)")
            let aside = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return SpottingLog()
        }
    }

    /// `~/Library/Containers/<app>/Data/Library/Application Support/FlightDesk/spotting-log.json`
    /// in the sandbox: private to the app (not the group container the widget shares).
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("FlightDesk", isDirectory: true).appendingPathComponent("spotting-log.json")
    }

    // MARK: CSV

    static let csvHeader = ["hex", "registration", "type", "operator", "first_seen", "last_seen", "sightings",
                            "closest_nm", "closest_at", "max_altitude_ft", "callsigns", "routes"]

    /// The given entries as CSV (RFC 4180, CRLF line ends, ISO 8601 UTC times).
    static func csv(_ list: [LogEntry]) -> String {
        let iso = ISO8601DateFormatter()
        var lines = [csvHeader.joined(separator: ",")]
        lines.reserveCapacity(list.count + 1)
        for e in list {
            let text = [e.hex.uppercased(), e.registration, e.typeCode, e.operatorName].map { csvField($0) }
            let rest = [iso.string(from: e.firstSeen), iso.string(from: e.lastSeen), String(e.sightings),
                        String(format: "%.1f", e.closestNM), iso.string(from: e.closestAt), String(e.maxAltitude)]
            let lists = [e.callsigns.joined(separator: " "), e.routes.joined(separator: " ")].map { csvField($0) }
            lines.append((text + rest + lists).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// One text field: quoted when it holds a comma, quote or line break (quotes doubled), and
    /// prefixed with `'` when it starts like a spreadsheet formula, as names come from the network.
    static func csvField(_ raw: String) -> String {
        var s = raw
        if let first = s.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) { s = "'" + s }
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

extension LogEntry {
    /// A new entry for a first observation.
    init(_ f: Flight, hex: String, at now: Date, group: String?) {
        self.hex = hex
        firstSeen = now
        lastSeen = now
        closestNM = Self.validDistance(f.distance) ?? .greatestFiniteMagnitude
        closestAt = now
        maxAltitude = f.altitude
        alertGroup = group
        absorbDetails(f)
    }

    /// Folds in another observation. Returns true when it starts a new sighting.
    mutating func merge(_ f: Flight, at now: Date, group: String?) -> Bool {
        var newSighting = false
        if now.timeIntervalSince(lastSeen) > SpottingLog.newSightingGap {
            sightings += 1
            newSighting = true
        }
        lastSeen = max(lastSeen, now)
        firstSeen = min(firstSeen, now)
        if let d = Self.validDistance(f.distance), d < closestNM {
            closestNM = d
            closestAt = now
        }
        maxAltitude = max(maxAltitude, f.altitude)
        if let group { alertGroup = group }
        absorbDetails(f)
        return newSighting
    }

    /// Registration, type, operator, callsign and route, keeping earlier values when the feed omits them.
    private mutating func absorbDetails(_ f: Flight) {
        // The feed falls back to the uppercase hex when it has no registration.
        let reg = f.reg.trimmingCharacters(in: .whitespaces)
        if !reg.isEmpty, reg.caseInsensitiveCompare(hex) != .orderedSame { registration = String(reg.prefix(12)) }
        let type = f.typeCode.trimmingCharacters(in: .whitespaces).uppercased()
        if !type.isEmpty { typeCode = String(type.prefix(8)) }
        let op = f.airlineName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !op.isEmpty { operatorName = String(op.prefix(80)) }
        if let icao = f.airlineICAO { airlineICAO = icao }
        if let iata = f.airlineCode, !iata.isEmpty { airlineIATA = iata.uppercased() }
        if let cs = AircraftID.callsign(f.callsign) {
            if callsigns.last != cs {
                callsigns.removeAll { $0 == cs }
                callsigns.append(cs)
                if callsigns.count > SpottingLog.callsignLimit { callsigns.removeFirst(callsigns.count - SpottingLog.callsignLimit) }
            }
        }
        if let r = f.route {
            let route = "\(r.from.code)-\(r.to.code)"
            if routes.last != route {
                routes.removeAll { $0 == route }
                routes.append(route)
                if routes.count > SpottingLog.routeLimit { routes.removeFirst(routes.count - SpottingLog.routeLimit) }
            }
        }
    }

    private static func validDistance(_ d: Double) -> Double? { d.isFinite && d >= 0 ? d : nil }

    /// Combines another record of the same airframe: the earliest first sighting, the latest last
    /// one, the larger visit count (the two logs may have seen the same visits), the higher
    /// altitude, the nearer pass, details from whichever saw it more recently (kept when the
    /// other omits them), and both callsign and route lists, most recent last.
    mutating func absorb(_ other: LogEntry) {
        guard other.hex == hex else { return }
        let otherIsNewer = other.lastSeen > lastSeen
        func pick(_ mine: String, _ theirs: String) -> String {
            theirs.isEmpty || (!mine.isEmpty && !otherIsNewer) ? mine : theirs
        }
        registration = pick(registration, other.registration)
        typeCode = pick(typeCode, other.typeCode)
        operatorName = pick(operatorName, other.operatorName)
        if let a = other.airlineICAO, airlineICAO == nil || otherIsNewer { airlineICAO = a }
        if let a = other.airlineIATA, airlineIATA == nil || otherIsNewer { airlineIATA = a }
        if alertGroup == nil { alertGroup = other.alertGroup }
        firstSeen = min(firstSeen, other.firstSeen)
        lastSeen = max(lastSeen, other.lastSeen)
        sightings = max(sightings, other.sightings)
        maxAltitude = max(maxAltitude, other.maxAltitude)
        if other.closestNM < closestNM {
            closestNM = other.closestNM
            closestAt = other.closestAt
        }
        func merged(_ mine: [String], _ theirs: [String], limit: Int) -> [String] {
            var out: [String] = []
            for item in otherIsNewer ? mine + theirs : theirs + mine {
                out.removeAll { $0 == item }
                out.append(item)
            }
            return Array(out.suffix(limit))
        }
        callsigns = merged(callsigns, other.callsigns, limit: SpottingLog.callsignLimit)
        routes = merged(routes, other.routes, limit: SpottingLog.routeLimit)
    }

    /// An entry from the FlightDesk server's sightings log, checked like feed data. The server
    /// measures distance from the centre of its area rather than from the user, so the closest
    /// pass is left unknown ("—") until this device sees the aircraft itself.
    init?(server s: ServerSighting) {
        guard let hex = AircraftID.hex(s.hex, allowNonICAO: false), s.firstSeen > 0, s.lastSeen >= s.firstSeen else { return nil }
        self.hex = hex
        firstSeen = Date(timeIntervalSince1970: TimeInterval(s.firstSeen))
        lastSeen = Date(timeIntervalSince1970: TimeInterval(s.lastSeen))
        sightings = max(1, s.sightings ?? 1)
        closestNM = .greatestFiniteMagnitude
        closestAt = lastSeen
        maxAltitude = max(0, s.maxAltitude ?? 0)
        func clean(_ v: String?, _ limit: Int) -> String {
            String((v ?? "").trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isNewline }.prefix(limit))
        }
        let reg = clean(s.registration, 12)
        registration = reg.caseInsensitiveCompare(hex) == .orderedSame ? "" : reg
        typeCode = clean(s.typeCode, 8).uppercased()
        operatorName = clean(s.operatorName, 80)
        if let icao = s.airlineICAO?.uppercased(), icao.count == 3, icao.allSatisfy({ $0.isASCII && $0.isLetter }) { airlineICAO = icao }
        callsigns = Array((s.callsigns ?? []).compactMap(AircraftID.callsign).suffix(SpottingLog.callsignLimit))
        routes = Array((s.routes ?? []).filter(Self.isRoute).suffix(SpottingLog.routeLimit))
    }

    /// "ORD-DEN": two airport codes of 3–4 letters or digits.
    private static func isRoute(_ r: String) -> Bool {
        let parts = r.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { (3...4).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) } }
    }
}
