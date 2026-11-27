// ACARS messages for the flight detail, from Airframes.io's public API (community ACARS, VDL2,
// HFDL and satcom receivers). Only the aircraft's ICAO hex and Airframes' own airframe and
// flight ids are ever sent. Foundation only: models, wire decoding, plain-English label
// decoding, current-flight matching and the polling policy are all unit-tested.

import Foundation

// MARK: - Model

/// Which way a message travelled.
enum AcarsDirection: Equatable, Sendable {
    /// Air-to-ground.
    case downlink
    /// Ground-to-air.
    case uplink
}

/// One of the four OOOI times airlines log for every flight.
enum OOOIEvent: Int, CaseIterable, Comparable, Sendable {
    /// Pushed back from the gate.
    case out
    /// Took off.
    case off
    /// Landed.
    case on
    /// Arrived at the gate.
    case arrivedIn

    var title: String {
        switch self {
        case .out: "Out"
        case .off: "Off"
        case .on: "On"
        case .arrivedIn: "In"
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// An Out/Off/On/In report.
struct OOOIReport: Equatable, Sendable {
    var kind: OOOIEvent
    var time: Date
}

/// A decoded ACARS (or VDL2/HFDL/satcom) message.
struct AcarsMessage: Identifiable, Equatable, Sendable {
    /// A decoded value shown under the message ("Position", "41.193° N, 141.675° E").
    struct Field: Equatable, Sendable {
        var name: String
        var value: String
    }

    let id: String
    let time: Date
    /// The two-character ARINC 620 label ("H1"), when the message has one.
    let label: String?
    /// What the message is, in plain English ("Wind data request").
    let plainLabel: String
    /// The message text with line endings normalised and trailing blanks removed.
    let text: String
    /// "ACARS", "VDL2", "HFDL" or "Satcom".
    let link: String
    /// The receiving station's public name on Airframes.io, when reported.
    let station: String?
    let direction: AcarsDirection?
    let fields: [Field]
    /// One sentence describing the contents, when they have a natural summary.
    let summary: String?
    /// Readable text carried inside an encoded message (MIAM), when it decoded.
    let decodedText: String?
    let event: OOOIReport?
    /// The route or position an FMS message reports (wind requests and position reports).
    let routeReport: AcarsRouteReport?
    /// A position given in an unambiguous format in the text, or by an FMS position report.
    let position: GeoPoint?
    /// Link maintenance with nothing to read (keep-alives, link tests, empty frames).
    let isNoise: Bool
}

/// The flight Airframes.io is tracking for the aircraft, with its messages.
struct AcarsFlight: Equatable, Sendable {
    let id: Int
    /// The flight number the aircraft reported ("DL2855").
    let flightNumber: String?
    /// ICAO codes of the departure and destination airports, when known.
    let departing: String?
    let destination: String?
    /// Those airports, when they have scheduled service (resolved while decoding, off the main thread).
    let departingAirport: Airport?
    let destinationAirport: Airport?
    /// Airframes' flight phase ("airborne"), when known.
    let phase: String?
    /// Messages Airframes has for the flight (more than `messages` holds for long flights).
    let messagesCount: Int
    /// Newest first, with copies heard by several receivers merged.
    let messages: [AcarsMessage]
    /// The earliest report of each OOOI event.
    let times: [OOOIEvent: Date]

    /// Messages worth reading (or all of them).
    func visibleMessages(showAll: Bool) -> [AcarsMessage] {
        showAll ? messages : messages.filter { !$0.isNoise }
    }

    /// What the messages say about the route, newest first.
    var routeReports: [AcarsRouteReport] { messages.compactMap(\.routeReport) }
}

// MARK: - Airframes.io wire format

/// The parts of Airframes.io's responses FlightDesk uses. Every field is optional and arrays
/// skip malformed elements, so a change in one record never hides the rest.
enum AirframesAPI {
    /// `/v1/airframes/icao/{hex}` and `/v1/airframes/{id}`.
    struct Airframe: Decodable {
        let id: Int
        let flights: Lossy<FlightSummary>?
    }

    /// One entry of an airframe's `flights`.
    struct FlightSummary: Decodable, Equatable, Sendable {
        let id: Int
        let flight: String?
        let flightIcao: String?
        let flightIata: String?
        let status: String?
        let departingAirport: String?
        let destinationAirport: String?
        let latitude: Double?
        let longitude: Double?
        let updatedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case id, flight, flightIcao, flightIata, status, departingAirport, destinationAirport, latitude, longitude, updatedAt
        }

        init(id: Int, flight: String?, flightIcao: String?, flightIata: String?, status: String?,
             departingAirport: String? = nil, destinationAirport: String? = nil,
             latitude: Double? = nil, longitude: Double? = nil, updatedAt: Date?) {
            self.id = id
            self.flight = flight
            self.flightIcao = flightIcao
            self.flightIata = flightIata
            self.status = status
            self.departingAirport = departingAirport
            self.destinationAirport = destinationAirport
            self.latitude = latitude
            self.longitude = longitude
            self.updatedAt = updatedAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(FlexibleID.self, forKey: .id).value
            flight = c.value(.flight, nil)
            flightIcao = c.value(.flightIcao, nil)
            flightIata = c.value(.flightIata, nil)
            status = c.value(.status, nil)
            departingAirport = c.value(.departingAirport, nil)
            destinationAirport = c.value(.destinationAirport, nil)
            latitude = c.value(.latitude, nil)
            longitude = c.value(.longitude, nil)
            updatedAt = c.value(.updatedAt, nil)
        }
    }

    /// `/v1/flights/{id}`: the flight with its latest (at most 200) messages, newest first.
    struct Flight: Decodable {
        let id: Int
        let flight: String?
        let departingAirport: String?
        let destinationAirport: String?
        let phase: String?
        let messagesCount: Int?
        let messages: Lossy<Message>?

        private enum CodingKeys: String, CodingKey {
            case id, flight, departingAirport, destinationAirport, phase, messagesCount, messages
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(FlexibleID.self, forKey: .id).value
            flight = c.value(.flight, nil)
            departingAirport = c.value(.departingAirport, nil)
            destinationAirport = c.value(.destinationAirport, nil)
            phase = c.value(.phase, nil)
            messagesCount = c.value(.messagesCount, nil)
            messages = c.value(.messages, nil)
        }
    }

    struct Message: Decodable {
        /// Only the station's public name is read; its owner and location are never decoded.
        struct Station: Decodable { let ident: String? }

        let id: Int
        let timestamp: Date
        let label: String?
        let text: String?
        let sourceType: String?
        let linkDirection: String?
        let fromHex: String?
        let toHex: String?
        let blockId: String?
        let station: Station?

        private enum CodingKeys: String, CodingKey {
            case id, timestamp, label, text, sourceType, linkDirection, fromHex, toHex, blockId, station
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(FlexibleID.self, forKey: .id).value
            timestamp = try c.decode(Date.self, forKey: .timestamp)
            label = c.value(.label, nil)
            text = c.value(.text, nil)
            sourceType = c.value(.sourceType, nil)
            linkDirection = c.value(.linkDirection, nil)
            fromHex = c.value(.fromHex, nil)
            toHex = c.value(.toHex, nil)
            blockId = c.value(.blockId, nil)
            station = c.value(.station, nil)
        }
    }

    /// An id sent as a number (flight lists) or a string (flight records).
    struct FlexibleID: Decodable {
        let value: Int
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int.self) {
                value = n
            } else if let n = Int(try c.decode(String.self)) {
                value = n
            } else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a numeric id")
            }
        }
    }

    /// An array that drops elements which fail to decode.
    struct Lossy<Element: Decodable>: Decodable {
        let elements: [Element]
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            var out: [Element] = []
            while !c.isAtEnd {
                if try c.decodeNil() { continue }
            if let e = try? c.decode(Element.self) { out.append(e) } else { _ = try c.decode(Skip.self) }
            }
            elements = out
        }
        /// Consumes one element of any shape.
        private struct Skip: Decodable { init(from decoder: Decoder) {} }
    }

    /// Decoder for Airframes' ISO 8601 timestamps (with or without fractional seconds).
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = (try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) ?? (try? Date(s, strategy: .iso8601)) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
        }
        return d
    }

    /// Decodes a response body; nil for the empty body Airframes sends when nothing matches.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T? {
        guard data.contains(where: { !$0.isWhitespace }) else { return nil }
        return try decoder().decode(T.self, from: data)
    }
}

private extension UInt8 {
    var isWhitespace: Bool { self == 0x20 || self == 0x0A || self == 0x0D || self == 0x09 }
}

// MARK: - Current flight

/// Picks the record of the flight the aircraft is flying now from an airframe's flight history.
enum AcarsFlightMatcher {
    /// How old a flight record may be and still be the current flight.
    static let maxAge: TimeInterval = 18 * 3_600
    /// Without a flight-number match, the record must be this fresh, in flight and near the aircraft.
    static let fallbackMaxAge: TimeInterval = 90 * 60
    static let fallbackMaxDistanceNM: Double = 300

    /// `callsign` is the live ADS-B callsign ("DAL2855"); `flightNumber` the scheduled IATA flight
    /// number when known ("DL2855"). Records are matched by flight number, then by callsign
    /// (Airframes sometimes copies the next leg's callsign onto a record, so a callsign match
    /// whose flight number contradicts it is ignored), then — only for a fresh, in-flight record
    /// near the aircraft — by recency. The most recently updated match wins.
    static func current(in flights: [AirframesAPI.FlightSummary], callsign: String, flightNumber: String?,
                        position: GeoPoint?, now: Date = Date()) -> AirframesAPI.FlightSummary? {
        let recent = flights.filter { f in
            guard let t = f.updatedAt else { return false }
            return now.timeIntervalSince(t) < maxAge && t.timeIntervalSince(now) < 600
        }
        let ours = flightNumber.flatMap { iata($0) }
        let cs = AircraftID.callsign(callsign)
        func numbers(_ f: AirframesAPI.FlightSummary) -> Set<Designated> {
            Set([f.flight, f.flightIata].compactMap { $0.flatMap(iata) })
        }
        func conflicts(_ f: AirframesAPI.FlightSummary) -> Bool {
            let theirs = numbers(f)
            guard !theirs.isEmpty else { return false }
            if let ours { return !theirs.contains(ours) }
            // Without a scheduled number, compare the callsign's flight part ("2855" of DAL2855).
            guard let suffix = cs.flatMap(icaoSuffix) else { return false }
            return !theirs.contains { $0.suffix == suffix }
        }
        let byNumber = recent.filter { f in ours.map { numbers(f).contains($0) } ?? false }
        let byCallsign = recent.filter { f in
            cs != nil && f.flightIcao.flatMap(AircraftID.callsign) == cs && !conflicts(f)
        }
        let byRecency = recent.filter { f in
            guard f.status == "in-flight", let t = f.updatedAt, now.timeIntervalSince(t) < fallbackMaxAge,
                  !conflicts(f) else { return false }
            guard let p = position, let lat = f.latitude, let lon = f.longitude else { return position == nil }
            return FlightService.gcDistance(p.lat, p.lon, lat, lon) <= fallbackMaxDistanceNM
        }
        for tier in [byNumber, byCallsign, byRecency] where !tier.isEmpty {
            return tier.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
        }
        return nil
    }

    /// A flight number split into airline designator and flight part, leading zeros dropped.
    struct Designated: Hashable {
        var airline: String
        var suffix: String
    }

    /// "DL0536" → DL / 536. Nil unless it's a 2-character designator plus a flight part starting with a digit.
    static func iata(_ raw: String) -> Designated? {
        let s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard s.count >= 3, s.count <= 8, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let rest = s.dropFirst(2)
        guard rest.first?.isNumber == true else { return nil }
        return Designated(airline: String(s.prefix(2)), suffix: trimmedZeros(rest))
    }

    /// "DAL0536" → "536": the flight part of an airline callsign.
    static func icaoSuffix(_ callsign: String) -> String? {
        let rest = callsign.dropFirst(3)
        guard callsign.prefix(3).allSatisfy(\.isLetter), rest.first?.isNumber == true else { return nil }
        return trimmedZeros(rest)
    }

    private static func trimmedZeros(_ s: Substring) -> String {
        let t = s.drop { $0 == "0" }
        return t.first?.isNumber == true ? String(t) : "0" + t
    }
}

// MARK: - Decoding messages

/// Plain-English decoding of ACARS messages. Label meanings follow ARINC 620; message texts are
/// largely airline-defined, so only widely used, verifiable formats are decoded.
enum AcarsDecoder {
    /// Labels that only maintain the link.
    static let noiseLabels: Set<String> = ["_d", "Q0", "SQ", "SA", "5V", "_\u{7F}"]

    /// What a message is, from its label and (for H1, the terminal message label) its text.
    static func plainLabel(_ label: String?, text: String) -> String {
        guard let label else { return "Link frame" }
        if label == "H1" { return h1Kind(core(text)) }
        if let event = oooiEvent(label) { return "\(event.title) report" }
        switch label {
        case "_d", "_\u{7F}": return "Keep-alive"
        case "Q0": return "Link test"
        case "SQ": return "Ground station beacon"
        case "SA": return "Link status"
        case "5V": return "VDL switch advisory"
        case "5Z": return "Airline ops"
        case "10": return "Departure / arrival report"
        case "11": return "In-range report"
        case "12": return "Crew event report"
        case "15", "16", "21", "22", "30", "57", "5R": return "Position report"
        case "17": return "Position / weather report"
        case "19": return "ATIS report"
        case "B9", "5D": return "ATIS request"
        case "1M", "4T", "Q1", "Q2", "3F": return "ETA report"
        case "20": return "Initialisation"
        case "23", "13": return "Loadsheet"
        case "24", "27", "28", "2S", "5U": return "Weather request"
        case "26": return "SIGMET"
        case "31", "4P", "4S", "2U", "H2": return "Weather report"
        case "33": return "Landing / performance data"
        case "39": return "Arrival message"
        case "44": return "Fuel / position report"
        case "46": return "Pilot report"
        case "4M": return "Cargo information"
        case "51", "52", "Q3": return "Clock update"
        case "54": return "Voice contact request"
        case "5Y", "QN": return "Diversion report"
        case "7A": return "Engine data"
        case "80", "83": return "Position / progress report"
        case "81", "82", "84", "85", "86", "87", "88", "89", "7B": return "Crew / dispatch message"
        case "8X", "A9": return "ATIS"
        case "A1": return "Oceanic clearance"
        case "A2", "A3": return "Departure clearance"
        case "A4", "B4": return "Departure clearance readback"
        case "A5": return "Position request"
        case "A6": return "ADS-C request"
        case "A7", "B7": return "ATC free text"
        case "AA", "BA": return "ATC datalink (CPDLC)"
        case "AB", "BB": return "Terminal weather"
        case "B0": return "ATS facility notification"
        case "B1": return "Oceanic clearance request"
        case "B2": return "Oceanic clearance readback"
        case "B3": return "Departure clearance request"
        case "B5": return "Waypoint position report"
        case "B6": return "ADS-C report"
        case "B8", "A8": return "Departure slot"
        case "C0", "C1", "C2", "C3", "C4", "C5", "C6", "C7", "C8", "C9", "CA": return "Cockpit printer message"
        case "H3": return "Icing report"
        case "HX", "Q5": return "Undelivered uplink"
        case "Q4": return "Voice circuit busy"
        case "Q6": return "Voice-to-data changeover"
        case "Q7": return "Delay report"
        case "QK": return "Landing report"
        case "QL", "QM": return "Arrival report"
        case "QX": return "Unable to process"
        case "RA", "RB": return "Command / response"
        case "S1", "S2", "S3": return "Link performance report"
        default: return "Message"
        }
    }

    /// H1 carries messages to and from onboard systems; the leading command says which.
    private static func h1Kind(_ core: String) -> String {
        let kinds: [(String, String)] = [
            ("REQPWI", "Wind data request"), ("PWI", "Wind data"),
            ("REQPOS", "Position request"), ("POS", "Position report"),
            ("REQPRG", "Progress report request"), ("PRG", "Progress report"),
            ("REQFPN", "Flight plan request"), ("FPN", "Flight plan"),
            ("REQPER", "Performance data request"), ("PER", "Performance data"),
            ("RES", "Acknowledgement"),
            ("FLR", "Fault report"), ("WRN", "Warning report"),
        ]
        for (prefix, kind) in kinds where core.hasPrefix(prefix) { return kind }
        return "Datalink message"
    }

    /// The OOOI event a label reports (ARINC 620 Q-labels).
    static func oooiEvent(_ label: String?) -> OOOIEvent? {
        switch label {
        case "QA", "QE", "QH", "QP": .out
        case "QB", "QF", "QQ": .off
        case "QC", "QR": .on
        case "QD", "QS": .arrivedIn
        default: nil
        }
    }

    /// `text` without an onboard-system address prefix ("- #M1B", "#CFB"): the command it carries.
    static func core(_ text: String) -> String {
        var s = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.hasPrefix("- ") { s = s.dropFirst(2) }
        if s.hasPrefix("#"), s.count > 4 {
            let tag = s.dropFirst().prefix(3)
            if tag.last == "B", tag.dropLast().allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                s = s.dropFirst(4)
                if s.hasPrefix("/"), let space = s.firstIndex(of: " ") { s = s[s.index(after: space)...] }
            }
        }
        return String(s)
    }

    /// Message text for display: CR/LF normalised, trailing blanks and blank lines removed.
    static func cleaned(_ text: String?) -> String {
        guard let text else { return "" }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                var l = line
                while l.last?.isWhitespace == true { l.removeLast() }
                return l
            }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return String(joined.prefix(4_000))
    }

    /// Direction from the explicit field, then the sender/recipient address, then the ACARS block
    /// id (ARINC 618: digits for downlinks, letters for uplinks).
    static func direction(link: String?, fromHex: String?, toHex: String?, blockID: String?, aircraftHex: String) -> AcarsDirection? {
        switch link?.lowercased() {
        case "downlink": return .downlink
        case "uplink": return .uplink
        default: break
        }
        if fromHex?.caseInsensitiveCompare(aircraftHex) == .orderedSame { return .downlink }
        if toHex?.caseInsensitiveCompare(aircraftHex) == .orderedSame { return .uplink }
        guard let b = blockID?.first, blockID?.count == 1, b.isASCII else { return nil }
        if b.isNumber { return .downlink }
        if b.isLetter { return .uplink }
        return nil
    }

    /// Display name of the link a message came over.
    static func linkName(_ sourceType: String?) -> String {
        switch sourceType?.lowercased() ?? "" {
        case "acars": "ACARS"
        case "vdl", "vdlm2", "vdl2": "VDL2"
        case "hfdl": "HFDL"
        case let s where s.hasPrefix("aero") || s.hasPrefix("sat") || s.hasPrefix("iridium") || s.hasPrefix("inmarsat"): "Satcom"
        case "": "ACARS"
        case let s: s.uppercased()
        }
    }

    // MARK: Text formats

    /// An OOOI report's event and time. ARINC 620 OOOI texts start with the origin and
    /// destination and the event time ("KLAXKLAS0334…"); otherwise the message time stands in.
    static func oooi(label: String?, text: String, sent: Date) -> (kind: OOOIEvent, time: Date, route: (from: String, to: String)?)? {
        guard let kind = oooiEvent(label) else { return nil }
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let m = match(oooiPattern, t), let h = Int(m[3]), let min = Int(m[4]), h < 24, min < 60 else {
            return (kind, sent, nil)
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard var time = utc.date(bySettingHour: h, minute: min, second: 0, of: sent) else { return (kind, sent, nil) }
        if time.timeIntervalSince(sent) > 600 { time = time.addingTimeInterval(-86_400) }
        guard sent.timeIntervalSince(time) < 12 * 3_600 else { return (kind, sent, nil) }
        return (kind, time, (m[1], m[2]))
    }
    private static let oooiPattern = regex("^([A-Z]{4})([A-Z]{4})([0-2][0-9])([0-5][0-9])")

    /// Flight levels in an FMS wind request ("WQ410.390" → FL410, FL390).
    static func windLevels(in core: String) -> [String] {
        guard core.hasPrefix("REQPWI"), let m = match(windLevelsPattern, core) else { return [] }
        return m[1].split(separator: ".").filter { $0.count == 3 && $0.allSatisfy(\.isNumber) }.map { "FL\($0)" }
    }
    private static let windLevelsPattern = regex("/WQ([0-9.]+):")

    /// The first position in `text` written in an unambiguous format: decimal degrees
    /// ("N 41.193/E141.675", "LAT N 58.253,LON E 20.112") or degrees and decimal minutes
    /// ("N5415.2,E01202.9", "4251.5N 8745.7W"). Packed digits without a decimal point
    /// ("N47462E000381") are skipped: airlines use them both as decimal degrees and as minutes.
    static func position(in text: String) -> GeoPoint? {
        func signed(_ v: Double, _ hemisphere: String) -> Double { hemisphere == "S" || hemisphere == "W" ? -v : v }
        func valid(_ lat: Double, _ lon: Double) -> GeoPoint? {
            abs(lat) <= 90 && abs(lon) <= 180 ? GeoPoint(lat: lat, lon: lon) : nil
        }
        if let m = match(decimalPattern, text), let lat = Double(m[2]), let lon = Double(m[4]) {
            return valid(signed(lat, m[1]), signed(lon, m[3]))
        }
        if let m = match(minutesPattern, text), let d1 = Double(m[2]), let m1 = Double(m[3]), let d2 = Double(m[5]), let m2 = Double(m[6]),
           m1 < 60, m2 < 60 {
            return valid(signed(d1 + m1 / 60, m[1]), signed(d2 + m2 / 60, m[4]))
        }
        if let m = match(minutesSuffixPattern, text), let d1 = Double(m[1]), let m1 = Double(m[2]), let d2 = Double(m[4]), let m2 = Double(m[5]),
           m1 < 60, m2 < 60 {
            return valid(signed(d1 + m1 / 60, m[3]), signed(d2 + m2 / 60, m[6]))
        }
        return nil
    }
    private static let decimalPattern = regex(#"(?<![0-9.])([NS]) ?([0-9]{1,2}\.[0-9]{2,})[ ,/]*(?:LON ?)?([EW]) ?([0-9]{1,3}\.[0-9]{2,})"#)
    private static let minutesPattern = regex(#"(?<![0-9.])([NS]) ?([0-9]{2})([0-5][0-9]\.[0-9]+)[ ,/]*([EW]) ?([0-9]{3})([0-5][0-9]\.[0-9]+)"#)
    private static let minutesSuffixPattern = regex(#"(?<![0-9.])([0-9]{2})([0-5][0-9]\.[0-9])([NS]) ?([0-9]{2,3})([0-5][0-9]\.[0-9])([EW])"#)

    /// "41.193° N, 141.675° E".
    static func format(_ p: GeoPoint) -> String {
        func f(_ v: Double, _ pos: String, _ neg: String) -> String { String(format: "%.3f° %@", abs(v), v < 0 ? neg : pos) }
        return "\(f(p.lat, "N", "S")), \(f(p.lon, "E", "W"))"
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants, covered by the unit tests.
        try! NSRegularExpression(pattern: pattern)
    }

    /// Capture groups of the first match (index 0 is the whole match; unmatched groups are "").
    private static func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }
}

extension AcarsMessage {
    /// Decodes a wire message heard from or for the aircraft `aircraftHex`.
    init(_ m: AirframesAPI.Message, aircraftHex: String) {
        let text = AcarsDecoder.cleaned(m.text)
        let core = AcarsDecoder.core(text)
        let label = m.label.flatMap { $0.isEmpty ? nil : $0 }
        let oooi = AcarsDecoder.oooi(label: label, text: core, sent: m.timestamp)
        let report = label == "H1" ? AcarsRouteParser.report(in: core, sent: m.timestamp) : nil
        let position = report?.position?.point ?? AcarsDecoder.position(in: core)
        let content = AcarsContentDecoder.decode(label: label, core: core, sent: m.timestamp, route: report)

        id = String(m.id)
        time = m.timestamp
        self.label = label
        plainLabel = content?.kind ?? AcarsDecoder.plainLabel(label, text: text)
        self.text = text
        link = AcarsDecoder.linkName(m.sourceType)
        station = m.station?.ident.flatMap { $0.isEmpty ? nil : String($0.prefix(40)) }
        direction = AcarsDecoder.direction(link: m.linkDirection, fromHex: m.fromHex, toHex: m.toHex,
                                           blockID: m.blockId, aircraftHex: aircraftHex)
        fields = content?.fields ?? position.map { [Field(name: "Position", value: AcarsDecoder.format($0))] } ?? []
        summary = content?.summary
        decodedText = content?.text
        event = oooi.map { OOOIReport(kind: $0.kind, time: $0.time) }
        routeReport = report
        self.position = position
        isNoise = label == nil || AcarsDecoder.noiseLabels.contains(label ?? "") || core.isEmpty
    }

    /// "03:34Z".
    static func utc(_ date: Date) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let d = c.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02dZ", d.hour ?? 0, d.minute ?? 0)
    }

    /// The same transmission heard by another receiver within two minutes. Copies can differ:
    /// some decoders keep the onboard-system prefix, and a receiver may miss later blocks.
    func isCopy(of other: AcarsMessage) -> Bool {
        guard label == other.label, abs(time.timeIntervalSince(other.time)) <= 120 else { return false }
        let a = AcarsDecoder.core(text), b = AcarsDecoder.core(other.text)
        if a == b { return true }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        return short.count >= 12 && (long.hasSuffix(short) || long.hasPrefix(short))
    }

    /// Fills what this copy lacks from `other` (direction, station, the fuller text).
    func merged(with other: AcarsMessage) -> AcarsMessage {
        let fuller = other.text.count > text.count ? other : self
        return AcarsMessage(id: id, time: min(time, other.time), label: label, plainLabel: fuller.plainLabel, text: fuller.text,
                            link: link, station: station ?? other.station, direction: direction ?? other.direction,
                            fields: fields.count >= other.fields.count ? fields : other.fields,
                            summary: fuller.summary ?? summary ?? other.summary, decodedText: fuller.decodedText ?? decodedText ?? other.decodedText,
                            event: event ?? other.event, routeReport: fuller.routeReport ?? routeReport ?? other.routeReport,
                            position: position ?? other.position, isNoise: isNoise && other.isNoise)
    }
}

extension AcarsFlight {
    /// Decodes a flight record for the aircraft `aircraftHex`: messages newest first with copies merged.
    init(_ f: AirframesAPI.Flight, aircraftHex: String) {
        let decoded = (f.messages?.elements ?? []).map { AcarsMessage($0, aircraftHex: aircraftHex) }
            .sorted { $0.time > $1.time }
        var unique: [AcarsMessage] = []
        for m in decoded {
            // Copies are heard within seconds of each other (`isCopy` looks two minutes either way).
            if let i = unique.lastIndex(where: { $0.isCopy(of: m) }) {
                unique[i] = unique[i].merged(with: m)
            } else {
                unique.append(m)
            }
        }
        unique.sort { $0.time > $1.time }   // a merged copy keeps the earliest time it was heard
        var times: [OOOIEvent: Date] = [:]
        for m in unique { if let e = m.event { times[e.kind] = min(times[e.kind] ?? e.time, e.time) } }

        id = f.id
        flightNumber = f.flight
        departing = f.departingAirport
        destination = f.destinationAirport
        departingAirport = f.departingAirport.flatMap(AirportDB.airport(code:))
        destinationAirport = f.destinationAirport.flatMap(AirportDB.airport(code:))
        phase = f.phase
        messagesCount = max(f.messagesCount ?? 0, unique.count)
        messages = unique
        self.times = times
    }

    /// The departure and destination as a route (with `scheduled`'s airline and number), when
    /// both are known airports.
    func route(scheduled: RouteInfo?) -> RouteInfo? {
        guard let from = departingAirport, let to = destinationAirport else { return nil }
        return RouteInfo(airline: scheduled?.airline, flightNo: scheduled?.flightNo, airlineCode: scheduled?.airlineCode, from: from, to: to)
    }
}

// MARK: - Service

/// Where an aircraft's ACARS lookup stands between refreshes.
struct AcarsCursor: Equatable, Sendable {
    var airframeID: Int?
    var flightID: Int?
    /// The callsign `flightID` was picked for; a new callsign means a new leg.
    var callsign = ""
    var listCheckedAt: Date?
    var messagesFetchedAt: Date?
}

/// What a refresh found.
enum AcarsResult: Equatable, Sendable {
    case flight(AcarsFlight)
    /// Airframes knows the aircraft but has no current flight for it.
    case noFlight
    /// Airframes has never heard the aircraft.
    case unknownAircraft
}

enum AcarsError: Error {
    /// Airframes.io asked us to slow down; `ApiBudget` says when it may be used again.
    case paused
    case http(Int)
}

/// Fetches ACARS data from Airframes.io for the detail view: airframe ids are cached on disk for
/// a day (shared with the widget's process like the other caches), the airframe's flight list is
/// re-read every 2 minutes while looking for the current flight and every 10 once found, and the
/// flight's messages at most every ~2 minutes. Requests are counted (and paused after a 429)
/// through `ApiBudget`.
actor AcarsService {
    static let shared = AcarsService()

    static let listSearchInterval: TimeInterval = 115
    static let listRecheckInterval: TimeInterval = 595
    static let messagesInterval: TimeInterval = 100
    /// How long a known airframe id, or "not known to Airframes", is reused.
    static let hitLifetime: TimeInterval = 86_400
    static let missLifetime: TimeInterval = 6 * 3_600

    private static let base = "https://api.airframes.io/v1"
    private static let maxEntries = 2_000

    /// A cached airframe lookup; `id == nil` records that Airframes doesn't know the aircraft.
    struct Entry: Codable, Equatable { var id: Int?; var at: Date }

    private var entries: [String: Entry]?
    private let fileURL: URL
    private let session: URLSession

    init(directory: URL = Shared.containerURL) {
        fileURL = directory.appendingPathComponent("acars-airframes.json")
        session = Net.session(Net.configuration(request: 10, resource: 30))
    }

    /// Advances `cursor` for the aircraft `hex` flying as `callsign` (scheduled as `flightNumber`)
    /// at `position`. Returns nil as the result when nothing was due.
    func refresh(hex: String, callsign: String, flightNumber: String?, position: GeoPoint?,
                 cursor: AcarsCursor, now: Date = Date()) async throws -> (AcarsResult?, AcarsCursor) {
        var c = cursor
        if c.callsign != callsign {
            c = AcarsCursor(airframeID: c.airframeID, callsign: callsign)
        }
        guard let key = AircraftID.hex(hex, allowNonICAO: false) else { return (.unknownAircraft, c) }
        if let answer = await viaServer(key, callsign: callsign, flightNumber: flightNumber, position: position,
                                        cursor: c, now: now) { return answer }
        if c.airframeID == nil { c.airframeID = try await airframeID(hex: key, now: now) }
        guard let airframe = c.airframeID else { return (.unknownAircraft, c) }

        if Self.isListDue(c, now: now) {
            let flights = try await flightList(airframe: airframe)
            c.listCheckedAt = now
            let pick = AcarsFlightMatcher.current(in: flights, callsign: callsign, flightNumber: flightNumber,
                                                  position: position, now: now)
            if pick?.id != c.flightID {
                c.flightID = pick?.id
                c.messagesFetchedAt = nil
            }
        }
        guard let id = c.flightID else { return (.noFlight, c) }
        if let t = c.messagesFetchedAt, now.timeIntervalSince(t) < Self.messagesInterval { return (nil, c) }
        let flight = try await flight(id: id, aircraftHex: key)
        c.messagesFetchedAt = now
        return (.flight(flight), c)
    }

    /// Whether the airframe's flight list should be re-read.
    static func isListDue(_ c: AcarsCursor, now: Date) -> Bool {
        guard let t = c.listCheckedAt else { return true }
        return now.timeIntervalSince(t) >= (c.flightID == nil ? listSearchInterval : listRecheckInterval)
    }

    // MARK: FlightDesk server

    /// The same refresh through the user's FlightDesk server (`/v1/acars`, which wraps Airframes'
    /// own records and caches them for every device), or nil to go to Airframes directly: server
    /// off, backing off, or this request failed. The current flight is picked here with
    /// `AcarsFlightMatcher`, exactly as for direct requests, and asked for by id when the server
    /// picked another.
    private func viaServer(_ key: String, callsign: String, flightNumber: String?, position: GeoPoint?,
                           cursor: AcarsCursor, now: Date) async -> (AcarsResult?, AcarsCursor)? {
        let server = FlightDeskServer.shared
        guard await server.isAvailable else { return nil }
        var c = cursor
        let listDue = Self.isListDue(c, now: now)
        if !listDue {
            guard let id = c.flightID else { return (.noFlight, c) }
            if let t = c.messagesFetchedAt, now.timeIntervalSince(t) < Self.messagesInterval { return (nil, c) }
            guard let r = await serverAcars(key, flight: id), let f = r.flight, r.flightId == id else { return nil }
            c.messagesFetchedAt = now
            return (.flight(AcarsFlight(f, aircraftHex: key)), c)
        }
        guard let first = await serverAcars(key, flight: nil) else { return nil }
        guard let airframe = first.airframeId else {
            store(Entry(id: nil, at: now), for: key)
            c.airframeID = nil
            return (.unknownAircraft, c)
        }
        if c.airframeID != airframe { store(Entry(id: airframe, at: now), for: key) }
        c.airframeID = airframe
        c.listCheckedAt = now
        let pick = AcarsFlightMatcher.current(in: first.airframe?.flights?.elements ?? [], callsign: callsign,
                                              flightNumber: flightNumber, position: position, now: now)
        if pick?.id != c.flightID {
            c.flightID = pick?.id
            c.messagesFetchedAt = nil
        }
        guard let id = c.flightID else { return (.noFlight, c) }
        if let t = c.messagesFetchedAt, now.timeIntervalSince(t) < Self.messagesInterval { return (nil, c) }
        let flight: AirframesAPI.Flight
        if first.flightId == id, let f = first.flight {
            flight = f
        } else {
            guard let r = await serverAcars(key, flight: id), r.flightId == id, let f = r.flight else { return nil }
            flight = f
        }
        c.messagesFetchedAt = now
        return (.flight(AcarsFlight(flight, aircraftHex: key)), c)
    }

    private func serverAcars(_ key: String, flight: Int?) async -> ServerAcarsResponse? {
        let query = flight.map { [("flight", String($0))] } ?? []
        guard let r = await FlightDeskServer.shared.get(["v1", "acars", key], query: query, limit: ResponseLimit.airframes),
              r.status == 200 else { return nil }
        return try? AirframesAPI.decoder().decode(ServerAcarsResponse.self, from: r.data)
    }

    // MARK: Requests

    private func get(_ segments: [String]) async throws -> Data {
        guard ApiBudget.isAvailable(.airframes) else { throw AcarsError.paused }
        guard let url = RemoteURL.make(Self.base, segments) else { throw URLError(.badURL) }
        let (data, response) = try await session.boundedData(from: url, limit: ResponseLimit.airframes)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            fdLog.info("Airframes.io \(segments.first ?? "", privacy: .public): HTTP \(status)")
            throw status == 429 ? AcarsError.paused : AcarsError.http(status)
        }
        return data
    }

    /// Airframes' id for the aircraft (`hex` lowercase), from the cache or by lookup. Airframes
    /// stores most addresses in uppercase and some in lowercase, and its lookup is exact.
    private func airframeID(hex: String, now: Date) async throws -> Int? {
        loadIfNeeded()
        if let e = entries?[hex], Self.isFresh(e, now: now) { return e.id }
        var found: Int?
        for variant in [hex.uppercased(), hex] {
            if let a = try AirframesAPI.decode(AirframesAPI.Airframe.self, from: try await get(["airframes", "icao", variant])) {
                found = a.id
                break
            }
        }
        store(Entry(id: found, at: now), for: hex)
        return found
    }

    private func flightList(airframe: Int) async throws -> [AirframesAPI.FlightSummary] {
        let data = try await get(["airframes", String(airframe)])
        return try AirframesAPI.decode(AirframesAPI.Airframe.self, from: data)?.flights?.elements ?? []
    }

    private func flight(id: Int, aircraftHex: String) async throws -> AcarsFlight {
        let data = try await get(["flights", String(id)])
        guard let f = try AirframesAPI.decode(AirframesAPI.Flight.self, from: data) else { throw AcarsError.http(404) }
        return AcarsFlight(f, aircraftHex: aircraftHex)
    }

    // MARK: Airframe cache

    static func isFresh(_ e: Entry, now: Date) -> Bool {
        now.timeIntervalSince(e.at) < (e.id == nil ? missLifetime : hitLifetime)
    }

    private func loadIfNeeded() {
        guard entries == nil else { return }
        entries = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: fileURL))) ?? [:]
    }

    /// Saves `entry`, merged with what the other process wrote meanwhile.
    private func store(_ entry: Entry, for key: String) {
        var all = entries ?? [:]
        all[key] = entry
        SharedFile.update(fileURL) { data in
            let disk = data.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
            all = Self.pruned(all.merging(disk) { mine, theirs in mine.at >= theirs.at ? mine : theirs }, now: entry.at)
            return try? JSONEncoder().encode(all)
        }
        entries = all
    }

    static func pruned(_ entries: [String: Entry], now: Date) -> [String: Entry] {
        let fresh = entries.filter { isFresh($0.value, now: now) }
        guard fresh.count > maxEntries else { return fresh }
        return Dictionary(uniqueKeysWithValues: fresh.sorted { $0.value.at > $1.value.at }.prefix(maxEntries * 3 / 4).map { ($0.key, $0.value) })
    }
}
