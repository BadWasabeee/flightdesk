// Spoken and written summaries of flights for Siri and Shortcuts, and the matching rules behind
// "Find Flight". Pure Foundation so the wording and matching are unit-tested (Tests/IntentsTests).

import Foundation

/// Sentences about flights, in the user's units: "United 1543, a Boeing 737 from Chicago to
/// Denver, 4 nautical miles north at 7,300 feet, descending."
enum FlightSpeech {
    /// Below this the aircraft is "directly overhead" rather than some distance away.
    static let overheadNM = 0.5
    /// Vertical rate (ft/min) that counts as climbing or descending (the boards' ▲/▼ threshold).
    static let climbFPM = 300.0

    // MARK: Pieces

    /// What to call the flight out loud: "United 1543" for an airline with a known name, else the
    /// callsign ("UAL1543"), else the registration ("N172SP").
    static func name(of f: Flight) -> String {
        if f.looksLikeAirline, let airline = spokenAirline(f.route?.airline), let number = flightNumber(of: f) {
            return "\(airline) \(number)"
        }
        if !f.callsign.isEmpty { return f.callsign }
        return f.reg
    }

    /// "Delta Air Lines" → "Delta", "United Airlines" → "United"; other names are kept whole
    /// ("British Airways", "JetBlue").
    static func spokenAirline(_ name: String?) -> String? {
        guard var n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return nil }
        for suffix in [" Air Lines", " Airlines"] where n.hasSuffix(suffix) && n.count > suffix.count {
            n.removeLast(suffix.count)
            break
        }
        return n
    }

    /// The number part of the flight: "UA1543" → "1543" (from the scheduled flight number), else the
    /// digits after an airline callsign's three-letter prefix ("UAL1543" → "1543").
    static func flightNumber(of f: Flight) -> String? {
        if let no = f.route?.flightNo, let code = f.route?.airlineCode, no.uppercased().hasPrefix(code.uppercased()), no.count > code.count {
            return String(no.dropFirst(code.count))
        }
        guard f.looksLikeAirline else { return nil }
        let rest = String(f.callsign.dropFirst(3))
        return rest.isEmpty ? nil : rest
    }

    /// The aircraft type as it reads aloud, with its article: "a Boeing 737", "an Airbus A321",
    /// "a Bell 407 helicopter", "a helicopter", or nil when nothing is known.
    static func aircraftPhrase(of f: Flight) -> String? {
        let rotorcraft = !f.typeCode.isEmpty && AircraftClass(typeCode: f.typeCode) == .rotorcraft
        var type = f.aircraft?.model.map(simplifiedModel) ?? ""
        if type.isEmpty { type = f.typeCode }
        if rotorcraft, !type.lowercased().contains("helicopter") {
            type = type.isEmpty ? "helicopter" : "\(type) helicopter"
        }
        guard !type.isEmpty else { return nil }
        return "\(article(for: type)) \(type)"
    }

    /// Drops the sub-variant from a model name so it reads naturally: "Boeing 737-800" → "Boeing 737",
    /// "Airbus A321-211" → "Airbus A321". Short variants that matter ("Boeing 787-9") are kept.
    static func simplifiedModel(_ model: String) -> String {
        let words = model.split(separator: " ").map { word -> String in
            guard let dash = word.lastIndex(of: "-") else { return String(word) }
            let head = word[..<dash], tail = word[word.index(after: dash)...]
            return tail.count >= 3 && head.contains(where: \.isNumber) && tail.first?.isNumber == true ? String(head) : String(word)
        }
        return words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// "a" or "an". Codes written in capitals are read letter by letter ("an F16", "a B738").
    static func article(for phrase: String) -> String {
        guard let first = phrase.first else { return "a" }
        let word = phrase.split(separator: " ").first.map(String.init) ?? phrase
        let isCode = word.contains(where: \.isNumber) && word == word.uppercased()
        if isCode { return "AEFHILMNORSX".contains(first.uppercased()) ? "an" : "a" }
        return "aeiou".contains(first.lowercased()) ? "an" : "a"
    }

    /// "from Chicago to Denver" (cities, else airport codes), toward the diversion airport when
    /// there is one, or just "from Chicago" while returning there; nil without a route.
    static func routePhrase(of f: Flight) -> String? {
        guard let r = f.route else { return nil }
        let to = f.destination ?? r.to
        func place(_ a: Airport) -> String { a.city.isEmpty ? a.code : a.city }
        guard r.from.code != to.code else { return "from \(place(r.from))" }
        return "from \(place(r.from)) to \(place(to))"
    }

    /// "4 nautical miles north", "7 kilometers southwest", "directly overhead".
    static func positionPhrase(of f: Flight, units: UnitSystem) -> String {
        guard f.distance >= overheadNM else { return "directly overhead" }
        return "\(distance(f.distance, units: units)) \(compassWord(f.direction))"
    }

    /// A distance in nautical miles, spoken in the user's units ("4 nautical miles", "1 kilometer").
    static func distance(_ nm: Double, units: UnitSystem) -> String {
        let (value, one, many) = units == .metric ? (nm * 1.852, "kilometer", "kilometers") : (nm, "nautical mile", "nautical miles")
        let n = max(1, Int(value.rounded()))
        return "\(n) \(n == 1 ? one : many)"
    }

    /// "7,300 feet" (to the nearest 100) or "2,230 meters" (to the nearest 10).
    static func altitude(_ ft: Int, units: UnitSystem, locale: Locale = .current) -> String {
        if units == .metric {
            let m = Int((Double(ft) * 0.3048 / 10).rounded()) * 10
            return "\(grouped(m, locale)) meters"
        }
        let rounded = ft >= 1_000 ? Int((Double(ft) / 100).rounded()) * 100 : Int((Double(ft) / 10).rounded()) * 10
        return "\(grouped(rounded, locale)) feet"
    }

    /// "climbing", "descending" or nil when holding altitude.
    static func verticalPhrase(of f: Flight) -> String? {
        f.verticalRate > climbFPM ? "climbing" : f.verticalRate < -climbFPM ? "descending" : nil
    }

    /// "N" → "north", "SW" → "southwest".
    static func compassWord(_ abbreviation: String) -> String {
        let words = ["N": "north", "NE": "northeast", "E": "east", "SE": "southeast",
                     "S": "south", "SW": "southwest", "W": "west", "NW": "northwest"]
        return words[abbreviation] ?? abbreviation
    }

    private static func grouped(_ n: Int, _ locale: Locale) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: Sentences

    /// One flight: "United 1543, a Boeing 737 from Chicago to Denver, 4 nautical miles north at
    /// 7,300 feet, descending." followed by any unusual situation ("Emergency, squawking 7700.").
    static func summary(of f: Flight, units: UnitSystem, locale: Locale = .current) -> String {
        var head = name(of: f)
        let what = [aircraftPhrase(of: f), routePhrase(of: f)].compactMap { $0 }.joined(separator: " ")
        if !what.isEmpty { head += ", \(what)" }
        var where_ = "\(positionPhrase(of: f, units: units)) at \(altitude(f.altitude, units: units, locale: locale))"
        if let v = verticalPhrase(of: f) { where_ += ", \(v)" }
        var text = "\(head), \(where_)."
        if let s = f.situation { text += " \(s.spoken)." }
        return text
    }

    /// The answer to "What's flying over me?": the nearest flight in full, then the next few by name.
    /// `radiusNM` words the empty answer.
    static func overhead(_ flights: [Flight], radiusNM: Int, units: UnitSystem, locale: Locale = .current, others: Int = 3) -> String {
        let sorted = flights.sorted { $0.distance < $1.distance }
        guard let nearest = sorted.first else {
            return "Nothing is flying within \(distance(Double(radiusNM), units: units)) right now."
        }
        var text = summary(of: nearest, units: units, locale: locale)
        let rest = sorted.dropFirst().prefix(others).map(name(of:))
        if !rest.isEmpty { text += " Also nearby: \(list(rest))." }
        return text
    }

    /// "3 flights within 25 nautical miles.", "1 flight within …", "No flights within …".
    static func nearbyCount(_ n: Int, radiusNM: Int, units: UnitSystem) -> String {
        let count = n == 0 ? "No flights" : n == 1 ? "1 flight" : "\(n) flights"
        return "\(count) within \(distance(Double(radiusNM), units: units))."
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}

/// How "Find Flight" picks an aircraft from what's nearby by callsign, flight number,
/// registration or ICAO hex address. Case, spaces and dashes don't matter.
enum FlightMatcher {
    /// Uppercase with spaces and dashes removed ("g-euuu " → "GEUUU", "ual 1543" → "UAL1543").
    static func normalized(_ s: String) -> String {
        s.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }

    /// Whether `query` names `f` exactly: its hex address, callsign, registration or scheduled
    /// flight number (IATA, "UA1543").
    static func matches(_ query: String, _ f: Flight) -> Bool {
        let q = normalized(query)
        guard !q.isEmpty else { return false }
        if let hex = AircraftID.hex(q), hex == f.id.lowercased() { return true }
        let candidates = [f.callsign, f.reg, f.route?.flightNo ?? ""].map(normalized)
        return candidates.contains { !$0.isEmpty && $0 == q }
    }

    /// The nearest flight in `flights` that `query` names, or nil.
    static func find(_ query: String, in flights: [Flight]) -> Flight? {
        flights.filter { matches(query, $0) }.min { $0.distance < $1.distance }
    }

    /// Flights whose callsign, registration, flight number or hex starts with `query` (Shortcuts'
    /// search-as-you-type), nearest first.
    static func search(_ query: String, in flights: [Flight]) -> [Flight] {
        let q = normalized(query)
        guard !q.isEmpty else { return flights.sorted { $0.distance < $1.distance } }
        return flights.filter { f in
            [f.callsign, f.reg, f.route?.flightNo ?? "", f.id].map(normalized).contains { !$0.isEmpty && $0.hasPrefix(q) }
        }.sorted { $0.distance < $1.distance }
    }
}
