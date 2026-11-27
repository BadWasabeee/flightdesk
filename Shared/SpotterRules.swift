// Spotter alerts: pure rule matching, plane-alert-db parsing, de-duplication and text formatting.
// No AppKit or UserNotifications here so it can be unit tested (the app layer lives in App/SpotterAlerts.swift).

import Foundation

// MARK: - CSV

enum CSV {
    /// Parses RFC 4180 CSV (quoted fields, `""` escapes, LF or CRLF line endings). Blank lines are skipped.
    static func parse(_ data: Data) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var pendingQuote = false            // saw a `"` inside quotes: either an escape or the closing quote
        let quote = UInt8(ascii: "\""), comma = UInt8(ascii: ","), lf = UInt8(ascii: "\n"), cr = UInt8(ascii: "\r")

        func endField() { row.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true) }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row.removeAll(keepingCapacity: true)
        }

        for byte in data {
            if inQuotes {
                if pendingQuote {
                    pendingQuote = false
                    if byte == quote { field.append(quote); continue }
                    inQuotes = false            // the previous quote closed the field; handle this byte normally
                } else if byte == quote {
                    pendingQuote = true
                    continue
                } else {
                    field.append(byte)
                    continue
                }
            }
            switch byte {
            case quote where field.isEmpty: inQuotes = true
            case comma: endField()
            case lf: endRow()
            case cr: break
            default: field.append(byte)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}

// MARK: - plane-alert-db

/// One row of the community [plane-alert-db](https://github.com/sdr-enthusiasts/plane-alert-db).
struct PlaneAlertEntry: Equatable, Sendable {
    let hex: String             // lowercase ICAO 24-bit address
    let registration: String
    let operatorName: String
    let type: String            // e.g. "Boeing C-17A Globemaster III"
    let icaoType: String        // e.g. "C17"
    let group: String           // `#CMPG`: Mil, Gov, Pol or Civ
    let tags: [String]
    let category: String        // e.g. "USAF", "Historic", "Police Forces"
    let link: String
}

/// The plane-alert-db list indexed by ICAO hex.
struct PlaneAlertDB: Equatable, Sendable {
    let entries: [String: PlaneAlertEntry]
    /// Category names with how many aircraft carry them, most common first.
    let categories: [(name: String, count: Int)]
    /// `#CMPG` group codes with counts.
    let groupCounts: [String: Int]

    /// Well-known `#CMPG` groups in display order.
    static let groups = ["Mil", "Gov", "Pol", "Civ"]

    static func groupTitle(_ code: String) -> String {
        switch code {
        case "Mil": "Military"
        case "Gov": "Government"
        case "Pol": "Police"
        case "Civ": "Civil"
        default: code
        }
    }

    /// Parses the CSV. Columns are located by header name (leading `$`/`#` markers ignored), so reordering is harmless.
    /// Returns nil when the header is missing the ICAO column.
    init?(csv data: Data) {
        let rows = CSV.parse(data)
        guard let header = rows.first else { return nil }
        let names = header.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "$# ")).lowercased() }
        func column(_ name: String) -> Int? { names.firstIndex(of: name) }
        guard let iHex = column("icao") else { return nil }
        let iReg = column("registration"), iOp = column("operator"), iType = column("type"), iIcaoType = column("icao type")
        let iGroup = column("cmpg"), iCat = column("category"), iLink = column("link")
        let iTags = ["tag 1", "tag 2", "tag 3"].compactMap(column)

        var entries: [String: PlaneAlertEntry] = [:]
        var catCounts: [String: Int] = [:], groupCounts: [String: Int] = [:]
        entries.reserveCapacity(rows.count)
        for row in rows.dropFirst() {
            func value(_ i: Int?) -> String {
                guard let i, i < row.count else { return "" }
                return row[i].trimmingCharacters(in: .whitespaces)
            }
            let hex = value(iHex).lowercased()
            guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { continue }
            let e = PlaneAlertEntry(hex: hex, registration: value(iReg), operatorName: value(iOp), type: value(iType),
                                    icaoType: value(iIcaoType).uppercased(), group: value(iGroup),
                                    tags: iTags.map(value).filter { !$0.isEmpty }, category: value(iCat), link: value(iLink))
            entries[hex] = e
            if !e.category.isEmpty { catCounts[e.category, default: 0] += 1 }
            if !e.group.isEmpty { groupCounts[e.group, default: 0] += 1 }
        }
        self.entries = entries
        self.groupCounts = groupCounts
        categories = catCounts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    subscript(hex: String) -> PlaneAlertEntry? { entries[hex.lowercased()] }

    static func == (a: PlaneAlertDB, b: PlaneAlertDB) -> Bool { a.entries == b.entries }
}

// MARK: - Settings

/// The rule that produced an alert, in priority order (earlier wins when one aircraft matches several).
enum SpotterRule: String, Codable, CaseIterable, Sendable {
    case emergency, watchlist, interesting, heavy, proximity
}

/// A user watchlist entry.
struct WatchItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case registration, hex, callsign, type

        var title: String {
            switch self {
            case .registration: "Registration"
            case .hex: "ICAO hex"
            case .callsign: "Callsign prefix"
            case .type: "Aircraft type"
            }
        }
        var placeholder: String {
            switch self {
            case .registration: "N12345, G-EUPT"
            case .hex: "a1b2c3"
            case .callsign: "DAL, N1"
            case .type: "A388, B748, C17"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    /// Normalized value (see `normalize(_:as:)`).
    var value: String

    /// Validates and normalizes user input, or returns nil if it can't be a value of that kind.
    static func normalize(_ raw: String, as kind: Kind) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let alnum = t.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        switch kind {
        case .hex:
            return t.count == 6 && t.allSatisfy(\.isHexDigit) ? t.lowercased() : nil
        case .type:
            return (2...4).contains(t.count) && alnum && t.first!.isLetter ? t : nil
        case .callsign:
            return (1...8).contains(t.count) && alnum ? t : nil
        case .registration:
            let r = regKey(t)
            return (2...10).contains(r.count) && r.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
                && t.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) ? t : nil
        }
    }

    /// Registrations compare without dashes/spaces ("G-EUPT" == "GEUPT").
    private static func regKey(_ s: String) -> String { s.uppercased().filter { $0 != "-" && $0 != " " } }

    func matches(_ f: Flight) -> Bool {
        switch kind {
        case .hex: f.id.lowercased() == value
        case .type: f.typeCode.uppercased() == value
        case .callsign: !f.callsign.isEmpty && f.callsign.uppercased().hasPrefix(value)
        case .registration: !f.reg.isEmpty && Self.regKey(f.reg) == Self.regKey(value)
        }
    }

    init(kind: Kind, value: String) { self.kind = kind; self.value = value }
}

/// Daily do-not-disturb window in local time. `start == end` means never quiet.
struct QuietHours: Codable, Equatable {
    var enabled = false
    var start = 22 * 60         // minutes after midnight
    var end = 7 * 60
    var allowEmergencies = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QuietHours()
        enabled = c.value(.enabled, d.enabled)
        start = c.value(.start, d.start)
        end = c.value(.end, d.end)
        allowEmergencies = c.value(.allowEmergencies, d.allowEmergencies)
    }

    func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, start != end else { return false }
        let p = calendar.dateComponents([.hour, .minute], from: date)
        let m = (p.hour ?? 0) * 60 + (p.minute ?? 0)
        return start < end ? (start..<end).contains(m) : (m >= start || m < end)   // window may wrap midnight
    }
}

/// Spotter alert preferences, stored as JSON under `SpotterSettings.key` in `Shared.defaults`.
struct SpotterSettings: Codable, Equatable {
    var emergencies = true
    var interesting = false
    /// plane-alert-db `#CMPG` groups to alert on (e.g. "Mil").
    var interestingGroups: Set<String> = ["Mil"]
    /// plane-alert-db categories to alert on in addition to the groups (e.g. "Historic").
    var interestingCategories: Set<String> = []
    var watchlistEnabled = true
    var watchlist: [WatchItem] = []
    var heavies = false
    var proximity = false
    var proximityNM = 2
    var quietHours = QuietHours()
    var menuBarReadout = false

    static let key = "spotter.settings.v1"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SpotterSettings()
        emergencies = c.value(.emergencies, d.emergencies)
        interesting = c.value(.interesting, d.interesting)
        interestingGroups = c.value(.interestingGroups, d.interestingGroups)
        interestingCategories = c.value(.interestingCategories, d.interestingCategories)
        watchlistEnabled = c.value(.watchlistEnabled, d.watchlistEnabled)
        // Drop individual unreadable items rather than the whole list.
        watchlist = ((try? c.decodeIfPresent([Lossy<WatchItem>].self, forKey: .watchlist)) ?? nil)?.compactMap(\.value) ?? d.watchlist
        heavies = c.value(.heavies, d.heavies)
        proximity = c.value(.proximity, d.proximity)
        proximityNM = c.value(.proximityNM, d.proximityNM)
        quietHours = c.value(.quietHours, d.quietHours)
        menuBarReadout = c.value(.menuBarReadout, d.menuBarReadout)
    }

    /// Rules that are switched on and can actually match something.
    var activeRules: Set<SpotterRule> {
        var r = Set<SpotterRule>()
        if emergencies { r.insert(.emergency) }
        if interesting, !(interestingGroups.isEmpty && interestingCategories.isEmpty) { r.insert(.interesting) }
        if watchlistEnabled, !watchlist.isEmpty { r.insert(.watchlist) }
        if heavies { r.insert(.heavy) }
        if proximity, proximityNM > 0 { r.insert(.proximity) }
        return r
    }

    static func decode(_ data: Data?) -> SpotterSettings {
        data.flatMap { try? JSONDecoder().decode(SpotterSettings.self, from: $0) } ?? SpotterSettings()
    }
}

private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Matching

/// One reason to notify about one aircraft.
struct SpotterAlert: Equatable {
    let flight: Flight
    let rule: SpotterRule
    /// Short reason, e.g. "Military", "Squawk 7700", "Watchlist".
    let label: String
    /// Optional plane-alert-db record for richer text.
    let entry: PlaneAlertEntry?
}

enum SpotterEngine {
    static let emergencySquawks: [String: String] = ["7500": "Hijack", "7600": "Radio failure", "7700": "Emergency"]

    /// All matches for every flight, grouped per aircraft in `SpotterRule` priority order.
    /// `squawk` supplies each aircraft's transponder code when the feed provides one.
    static func evaluate(_ flights: [Flight], settings: SpotterSettings, db: PlaneAlertDB?,
                         squawk: (Flight) -> String?) -> [SpotterAlert] {
        let active = settings.activeRules
        guard !active.isEmpty else { return [] }
        return flights.flatMap { matches(for: $0, settings: settings, active: active, db: db, squawk: squawk($0)) }
    }

    static func matches(for f: Flight, settings: SpotterSettings, active: Set<SpotterRule>,
                        db: PlaneAlertDB?, squawk: String?) -> [SpotterAlert] {
        let entry = db?[f.id]
        var out: [SpotterAlert] = []
        for rule in SpotterRule.allCases where active.contains(rule) {
            let label: String?
            switch rule {
            case .emergency:
                label = squawk.flatMap { code in emergencySquawks[code].map { "\($0) · squawk \(code)" } }
            case .watchlist:
                label = settings.watchlist.contains { $0.matches(f) } ? "Watchlist" : nil
            case .interesting:
                if let e = entry {
                    if settings.interestingGroups.contains(e.group) { label = PlaneAlertDB.groupTitle(e.group) }
                    else if settings.interestingCategories.contains(e.category) { label = e.category }
                    else { label = nil }
                } else { label = nil }
            case .heavy:
                label = AircraftClass(typeCode: f.typeCode) == .wideBody ? "Heavy" : nil
            case .proximity:
                label = f.distance <= Double(settings.proximityNM) ? "Close approach" : nil
            }
            if let label { out.append(SpotterAlert(flight: f, rule: rule, label: label, entry: entry)) }
        }
        return out
    }

    /// Drops what quiet hours suppress (everything, or everything but emergencies).
    static func applyQuietHours(_ alerts: [SpotterAlert], _ q: QuietHours, at now: Date, calendar: Calendar = .current) -> [SpotterAlert] {
        guard q.isQuiet(at: now, calendar: calendar) else { return alerts }
        return q.allowEmergencies ? alerts.filter { $0.rule == .emergency } : []
    }
}

// MARK: - De-duplication

/// Remembers which (rule, aircraft) pairs were notified recently so each fires at most once per `window`.
struct AlertLedger: Codable, Equatable {
    static let window: TimeInterval = 2 * 3600
    static let key = "spotter.ledger.v1"

    private(set) var sent: [String: Date] = [:]

    private static func key(_ rule: SpotterRule, _ hex: String) -> String { "\(rule.rawValue)|\(hex.lowercased())" }

    func isRecent(_ rule: SpotterRule, hex: String, now: Date) -> Bool {
        guard let t = sent[Self.key(rule, hex)] else { return false }
        return now.timeIntervalSince(t) < Self.window
    }

    mutating func record(_ rule: SpotterRule, hex: String, now: Date) { sent[Self.key(rule, hex)] = now }

    mutating func prune(now: Date) { sent = sent.filter { now.timeIntervalSince($0.value) < Self.window } }

    /// Picks at most one alert per aircraft (its highest-priority rule not sent recently) and records every
    /// fresh rule for that aircraft so lesser rules don't follow up. At most `limit` aircraft per call;
    /// the rest stay unrecorded and are offered again next time.
    mutating func admit(_ candidates: [SpotterAlert], now: Date, limit: Int = 3) -> [SpotterAlert] {
        var order: [String] = []
        var byHex: [String: [SpotterAlert]] = [:]
        for a in candidates where !isRecent(a.rule, hex: a.flight.id, now: now) {
            if byHex[a.flight.id] == nil { order.append(a.flight.id) }
            byHex[a.flight.id, default: []].append(a)
        }
        let chosen = order.compactMap { byHex[$0]?.min { rank($0.rule) < rank($1.rule) } }
            .sorted { rank($0.rule) != rank($1.rule) ? rank($0.rule) < rank($1.rule) : $0.flight.distance < $1.flight.distance }
            .prefix(limit)
        for a in chosen { byHex[a.flight.id]?.forEach { record($0.rule, hex: $0.flight.id, now: now) } }
        return Array(chosen)
    }

    private func rank(_ r: SpotterRule) -> Int { SpotterRule.allCases.firstIndex(of: r) ?? 0 }
}

// MARK: - Text

extension SpotterAlert {
    /// The aircraft's best available name: plane-alert-db type, else the ICAO type code.
    var aircraftName: String {
        if let t = entry?.type, !t.isEmpty { return t }
        return flight.typeCode.isEmpty ? "Aircraft" : flight.typeCode
    }

    /// e.g. "Military · Boeing C-17A Globemaster III overhead".
    var title: String { "\(label) · \(aircraftName) \(flight.distance <= 3 ? "overhead" : "nearby")" }

    /// e.g. "RCH123 · 07-7183 · US Air Force\n24,000 ft · 4.2 nm NE".
    func body(display: DisplayOptions) -> String {
        var d = display
        d.style = .standard
        let f = flight
        let reg = entry?.registration.isEmpty == false ? entry!.registration : f.reg
        let op = entry?.operatorName.isEmpty == false ? entry!.operatorName : f.airlineName
        var who: [String] = [f.displayNumber]
        if !reg.isEmpty, reg != f.displayNumber { who.append(reg) }
        if !op.isEmpty { who.append(op) }
        let climb = f.climbSymbol.isEmpty ? "" : " \(f.climbSymbol)"
        return who.joined(separator: " · ") + "\n" + "\(d.altitude(f.altitude))\(climb) · \(d.distance(f.distance)) \(f.direction)"
    }
}

// MARK: - Menu-bar readout

enum MenuBarReadout {
    /// Nearest airline flight as "DL1342 · 4.0 nm", or nil when none is around.
    /// `known` (e.g. the enriched panel list) supplies a flight number when it has one for the same aircraft.
    static func text(flights: [Flight], known: [Flight] = [], display: DisplayOptions) -> String? {
        guard let f = flights.filter(\.looksLikeAirline).min(by: { $0.distance < $1.distance }) else { return nil }
        var d = display
        d.style = .standard
        let number = known.first { $0.id == f.id }?.displayNumber ?? f.displayNumber
        return "\(number) · \(d.distance(f.distance))"
    }
}
