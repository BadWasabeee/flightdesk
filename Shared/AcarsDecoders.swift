// Readable decodes of ACARS message contents. Each decoder handles one format verified against
// real messages from the Airframes.io feed and returns nil rather than guess; message texts are
// largely airline-defined, so anything else is shown as sent.
//
// The MIAM (ARINC 841) and ARINC 622 (FANS-1/A) framing follows libacars by Tomasz Lemiech
// (https://github.com/szpajder/libacars, MIT licence): base85 coding, MIAM CORE v1/v2 data PDU
// headers, raw-deflate bodies, the CRC-32 (ARINC 665) and CRC-16 (ARINC) checks, and the ADS-C
// basic report layout.

import Compression
import Foundation

/// What a message's contents say, in plain English.
struct AcarsContent: Equatable, Sendable {
    /// What the message is, when the contents tell more than the label ("MIAM compressed message").
    var kind: String?
    /// One sentence, when the contents have a natural summary.
    var summary: String?
    /// Decoded values, in reading order.
    var fields: [AcarsMessage.Field] = []
    /// Readable text carried inside an encoded message (MIAM), shown in place of the raw text.
    var text: String?
}

enum AcarsContentDecoder {
    /// The contents of a message with `label`, its text with any onboard-system prefix removed
    /// (`core`), sent at `sent`; `route` is its route report, when it has one.
    static func decode(label: String?, core: String, sent: Date, route: AcarsRouteReport?) -> AcarsContent? {
        switch label {
        case "H1":
            if let route { return self.route(route, core: core) }
            return nil
        case "MA":
            return miam(core)
        case "AA", "BA", "A6", "B6":
            return arinc622(core, downlink: label == "B6" || label == "BA")
        case "A9", "HX":
            return atis(core)
        case "B9":
            return atisRequest(core)
        case "B1":
            return oceanicClearanceRequest(core)
        case "B3":
            return departureClearanceRequest(core)
        case "A3":
            return departureClearance(core)
        case "A4":
            return clearanceStatus(core)
        default:
            if let kind = AcarsDecoder.oooiEvent(label) { return oooi(kind, core: core, sent: sent) }
            return performanceData(core)
        }
    }

    // MARK: FMS route messages

    private static func route(_ r: AcarsRouteReport, core: String) -> AcarsContent? {
        switch r.kind {
        case .position: return positionReport(core, report: r)
        case .windRequest: return windRequest(core, report: r)
        case .flightPlan: return flightPlan(core, report: r)
        }
    }

    /// `POSN42285W087484,BRTMN,035113,174,TAAYZ,035331,PETTY,M15,06645,…`: position, last
    /// waypoint passed, report time (the time of the position, not of passing the waypoint, which
    /// can be far behind), flight level, next waypoint and ETA, the one after, outside air
    /// temperature (M = minus, P = plus) and wind (direction in degrees, then knots). Later fields
    /// vary by aircraft and are left out.
    static func positionReport(_ core: String, report: AcarsRouteReport) -> AcarsContent? {
        guard let position = report.position else { return nil }
        let f = core.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        var fields = [AcarsMessage.Field(name: "Position", value: describe(position.point))]
        func fix(_ i: Int) -> String? { i < f.count - 1 ? AcarsRouteParser.token(f[i][...])?.label : nil }
        if AcarsRouteParser.utcTime(f[2][...], near: report.time) != nil {
            fields.append(.init(name: "Reported", value: utcSeconds(position.time)))
        }
        if let passed = fix(1) { fields.append(.init(name: "Last waypoint", value: passed)) }
        if f.count > 4, let fl = Int(f[3]), (0...600).contains(fl) {
            fields.append(.init(name: "Altitude", value: String(format: "FL%03d", fl)))
        }
        if let next = fix(4) {
            let eta = f.count > 6 ? eta(f[5], after: position.time) : nil
            fields.append(.init(name: "Next", value: eta.map { "\(next) at \(AcarsMessage.utc($0))" } ?? next))
        }
        if let then = fix(6) { fields.append(.init(name: "Then", value: then)) }
        if f.count > 8, let t = temperature(f[7]) { fields.append(.init(name: "Outside air", value: t)) }
        if f.count > 9, let w = wind(f[8]) { fields.append(.init(name: "Wind", value: w)) }
        return AcarsContent(fields: fields)
    }

    /// `hhmmss` (UTC) as the first such moment after `time` (allowing a minute's skew), within twelve hours.
    static func eta(_ s: String, after time: Date) -> Date? {
        guard s.count == 6, let n = Int(s), n / 10_000 < 24, n / 100 % 100 < 60, n % 100 < 60 else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard var t = utc.date(bySettingHour: n / 10_000, minute: n / 100 % 100, second: n % 100, of: time) else { return nil }
        if t < time.addingTimeInterval(-60) { t.addTimeInterval(86_400) }
        return t.timeIntervalSince(time) < 12 * 3_600 ? t : nil
    }

    /// "M15" → "−15 °C".
    static func temperature(_ s: String) -> String? {
        guard let sign = s.first, sign == "M" || sign == "P", (2...3).contains(s.count), let v = Int(s.dropFirst()), v <= 99 else { return nil }
        return v == 0 ? "0 °C" : "\(sign == "M" ? "−" : "")\(v) °C"
    }

    /// "06645" → "066° at 45 kt", "252101" → "252° at 101 kt".
    static func wind(_ s: String) -> String? {
        guard (5...6).contains(s.count), s.allSatisfy(\.isNumber), let dir = Int(s.prefix(3)), let speed = Int(s.dropFirst(3)),
              dir <= 360, speed < 300 else { return nil }
        return String(format: "%03d° at %d kt", dir, speed)
    }

    /// `REQPWI/…/WQ370.380:…`: the FMS asks for forecast winds at those levels along its route.
    static func windRequest(_ core: String, report: AcarsRouteReport) -> AcarsContent? {
        let levels = AcarsDecoder.windLevels(in: core)
        let names = report.waypoints.map(\.label)
        guard let first = names.first, let last = names.last else { return nil }
        // "FL" plus three digits, so they sort as text.
        let range = levels.count > 1 ? "\(levels.min() ?? "")–\(levels.max() ?? "")" : levels.first
        let path = names.count > 2 ? "\(first) → … → \(last)" : names.joined(separator: " → ")
        let waypoints = names.count == 1 ? "1 waypoint" : "\(names.count) waypoints"
        var fields: [AcarsMessage.Field] = []
        if !levels.isEmpty { fields.append(.init(name: "Levels", value: levels.joined(separator: ", "))) }
        fields.append(.init(name: "Route", value: names.joined(separator: " ")))
        return AcarsContent(summary: "Requested winds\(range.map { " for \($0)" } ?? "") along \(waypoints): \(path)", fields: fields)
    }

    /// `FPN/…:DA:LBSF:AA:EPWA:F:…`: a flight plan, with its departure (DA) and arrival (AA) airports.
    static func flightPlan(_ core: String, report: AcarsRouteReport) -> AcarsContent? {
        func airport(_ key: String) -> String? {
            let parts = core.split(separator: ":", omittingEmptySubsequences: false)
            guard let i = parts.firstIndex(where: { $0 == key || $0.hasSuffix("/" + key) }), i + 1 < parts.count else { return nil }
            let code = parts[i + 1].prefix(4)
            return code.count == 4 && code.allSatisfy({ $0.isASCII && $0.isUppercase }) ? String(code) : nil
        }
        let names = report.waypoints.map(\.label)
        let from = airport("DA"), to = airport("AA")
        let endpoints = from.flatMap { f in to.map { "\(f) → \($0)" } }
        var fields: [AcarsMessage.Field] = []
        if let endpoints { fields.append(.init(name: "Route", value: endpoints)) }
        fields.append(.init(name: "Waypoints", value: names.joined(separator: " ")))
        return AcarsContent(summary: "Flight plan\(endpoints.map { " \($0)" } ?? "") via \(names.count) waypoints", fields: fields)
    }

    // MARK: Gate and runway times

    /// ARINC 620 OOOI reports: event, airports and time ("KLAXKLAS0334…").
    static func oooi(_ kind: OOOIEvent, core: String, sent: Date) -> AcarsContent? {
        guard let o = AcarsDecoder.oooi(label: label(for: kind), text: core, sent: sent) else { return nil }
        var fields = [AcarsMessage.Field(name: kind.title, value: AcarsMessage.utc(o.time))]
        guard let r = o.route else { return AcarsContent(fields: fields) }
        fields.append(.init(name: "Route", value: "\(r.from) → \(r.to)"))
        let summary: String
        switch kind {
        case .out: summary = "Pushed back from the gate at \(r.from), \(AcarsMessage.utc(o.time))"
        case .off: summary = "Took off from \(r.from), \(AcarsMessage.utc(o.time))"
        case .on: summary = "Landed at \(r.to), \(AcarsMessage.utc(o.time))"
        case .arrivedIn: summary = "Arrived at the gate at \(r.to), \(AcarsMessage.utc(o.time))"
        }
        return AcarsContent(summary: summary, fields: fields)
    }

    private static func label(for kind: OOOIEvent) -> String {
        switch kind {
        case .out: "QA"
        case .off: "QB"
        case .on: "QC"
        case .arrivedIn: "QD"
        }
    }

    // MARK: Weather

    /// D-ATIS uplinks: `/ATSF9XA.TI2/KLAX ARR ATIS M\n0353Z LAX ATIS INFO M 0353Z. 00000KT 10SM …`.
    static func atis(_ core: String) -> AcarsContent? {
        guard let m = match(atisPattern, core) else { return nil }
        let kind = m[2] == "ARR" ? "arrival " : m[2] == "DEP" ? "departure " : ""
        var fields: [AcarsMessage.Field] = []
        let body = String(core[core.index(core.startIndex, offsetBy: m[0].count)...])
        if let t = match(atisTimePattern, body) { fields.append(.init(name: "Issued", value: "\(t[1])Z")) }
        fields += metar(body)
        return AcarsContent(kind: "ATIS", summary: "\(m[1]) \(kind)ATIS information \(m[3])", fields: fields)
    }
    private static let atisPattern = regex(#"^/[A-Z0-9]{7}\.TI2/([A-Z]{4}) (?:(ARR|DEP) )?ATIS ([A-Z])\b"#)
    private static let atisTimePattern = regex(#"^\s*([0-2][0-9][0-5][0-9])Z"#)

    /// `/KJFK.TI2/024KJFKA6588`: a request for an airport's ATIS.
    static func atisRequest(_ core: String) -> AcarsContent? {
        guard let m = match(atisRequestPattern, core) else { return nil }
        return AcarsContent(summary: "ATIS requested for \(m[1])")
    }
    private static let atisRequestPattern = regex(#"^/([A-Z]{4})\.TI2/"#)

    /// The METAR groups in a weather text: wind, visibility, cloud, temperature and altimeter
    /// setting. Only groups in the standard METAR forms are read.
    static func metar(_ text: String) -> [AcarsMessage.Field] {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map { String($0.trimmingCharacters(in: .punctuationCharacters)) }
        var fields: [AcarsMessage.Field] = []
        var clouds: [String] = []
        for t in tokens {
            if fields.contains(where: { $0.name == "Wind" }) == false, let m = match(windGroup, t) {
                let speed = Int(m[2]) ?? 0
                let gust = m[3].isEmpty ? "" : ", gusting \(Int(m[3].dropFirst()) ?? 0) kt"
                fields.append(.init(name: "Wind", value: m[1] == "000" && speed == 0 ? "Calm" :
                                        "\(m[1] == "VRB" ? "Variable" : "\(m[1])°") at \(speed) kt\(gust)"))
            } else if t == "CAVOK" {
                fields.append(.init(name: "Visibility", value: "10 km or more, no significant cloud"))
            } else if !fields.contains(where: { $0.name == "Visibility" }), let m = match(visibilitySM, t) {
                fields.append(.init(name: "Visibility", value: "\(m[1]) statute miles"))
            } else if let m = match(cloudGroup, t), let base = Int(m[2]) {
                let cover = ["FEW": "Few", "SCT": "Scattered", "BKN": "Broken", "OVC": "Overcast"][m[1]] ?? m[1]
                clouds.append("\(cover) at \((base * 100).formatted()) ft")
            } else if !fields.contains(where: { $0.name == "Temperature" }), let m = match(temperatureGroup, t) {
                func c(_ s: String) -> String { s.hasPrefix("M") ? "−\(Int(s.dropFirst()) ?? 0)" : "\(Int(s) ?? 0)" }
                fields.append(.init(name: "Temperature", value: "\(c(m[1])) °C, dew point \(c(m[2])) °C"))
            } else if !fields.contains(where: { $0.name == "Altimeter" }), let m = match(altimeterGroup, t), let v = Int(m[2]) {
                fields.append(.init(name: "Altimeter", value: m[1] == "A" ? String(format: "%.2f inHg", Double(v) / 100) : "\(v) hPa"))
            }
        }
        if !clouds.isEmpty { fields.insert(.init(name: "Cloud", value: clouds.joined(separator: ", ")), at: min(fields.count, 2)) }
        return fields
    }
    private static let windGroup = regex(#"^([0-3][0-9]0|VRB)([0-9]{2,3})(G[0-9]{2,3})?KT$"#)
    private static let visibilitySM = regex(#"^([0-9]{1,2})SM$"#)
    private static let cloudGroup = regex(#"^(FEW|SCT|BKN|OVC)([0-9]{3})$"#)
    private static let temperatureGroup = regex(#"^(M?[0-9]{2})/(M?[0-9]{2})$"#)
    private static let altimeterGroup = regex(#"^(A|Q)([0-9]{4})$"#)

    // MARK: Clearances

    /// `/REKCLXS.OC1/RCL 024\nGTI6079-RATSU/0503 M082F300\n-RMK/MAX FL340`: an oceanic clearance
    /// request (flight, entry point and time, Mach, level, and the highest level it can accept).
    static func oceanicClearanceRequest(_ core: String) -> AcarsContent? {
        guard let m = match(oceanicPattern, core), let mach = Int(m[5]), let level = Int(m[6]) else { return nil }
        var fields: [AcarsMessage.Field] = [
            .init(name: "Entry", value: "\(m[3]) at \(m[4].prefix(2)):\(m[4].suffix(2))Z"),
            .init(name: "Speed", value: String(format: "Mach %.2f", Double(mach) / 100)),
            .init(name: "Level", value: String(format: "FL%03d", level)),
        ]
        if let max = match(maxLevelPattern, core) { fields.append(.init(name: "Highest acceptable", value: "FL\(max[1])")) }
        // A four-letter address is the oceanic centre itself ("CZQX"); seven characters are a datalink address.
        let centre = m[1].count == 4 ? " from \(m[1])" : ""
        return AcarsContent(kind: "Oceanic clearance request", summary: "\(m[2]) requests oceanic clearance\(centre)", fields: fields)
    }
    private static let oceanicPattern = regex(#"^/([A-Z0-9]{4}|[A-Z0-9]{7})\.OC1/RCL [0-9]+\s+([A-Z0-9]{3,8})-([A-Z0-9]{2,11})/([0-2][0-9][0-5][0-9]) M([0-9]{3})F([0-9]{3})"#)
    private static let maxLevelPattern = regex(#"-RMK/MAX F(?:L)?([0-9]{3})"#)

    /// `/LEVC.DC1/RCD 000\nPVG127P-LEVC-GATE 54-GCLP\nATIS E\n-TYP/A321…`: a departure clearance request.
    static func departureClearanceRequest(_ core: String) -> AcarsContent? {
        guard let m = match(clearanceRequestPattern, core) else { return nil }
        var fields = [AcarsMessage.Field(name: "Route", value: "\(m[2]) → \(m[4])")]
        if !m[3].isEmpty { fields.append(.init(name: "Gate", value: m[3])) }
        if let atis = match(atisLetterPattern, core) { fields.append(.init(name: "ATIS", value: atis[1])) }
        return AcarsContent(kind: "Departure clearance request", summary: "\(m[1]) requests departure clearance at \(m[2])", fields: fields)
    }
    private static let clearanceRequestPattern = regex(#"^/[A-Z0-9]{4,7}\.DC1/RCD [0-9]+\s+([A-Z0-9]{3,8})-([A-Z]{4})-(?:GATE ([A-Z0-9]{1,5})-)?([A-Z]{4})\b"#)
    private static let atisLetterPattern = regex(#"\n\s*ATIS ([A-Z])\b"#)

    /// `/ANPOC5Y.DC1/CLD 0403 261127 PANC\nPDC 2\nGTI875 PANC-ZHEC\nSQUAWK: 7220\n…FILED FL: 380`:
    /// a pre-departure clearance; only the clearly labelled items are read.
    static func departureClearance(_ core: String) -> AcarsContent? {
        guard core.contains(".DC1/CLD "), let flight = match(pdcFlightPattern, core) else { return nil }
        var fields = [AcarsMessage.Field(name: "Route", value: "\(flight[2]) → \(flight[3])")]
        if let s = match(squawkPattern, core) { fields.append(.init(name: "Squawk", value: s[1])) }
        if let fl = match(filedLevelPattern, core) { fields.append(.init(name: "Filed level", value: "FL\(fl[1])")) }
        return AcarsContent(kind: "Departure clearance", summary: "Departure clearance for \(flight[1])", fields: fields)
    }
    private static let pdcFlightPattern = regex(#"\n\s*([A-Z0-9]{3,8}) ([A-Z]{4})-([A-Z]{4})\s*\n"#)
    private static let squawkPattern = regex(#"SQUAWK:? ?([0-7]{4})\b"#)
    private static let filedLevelPattern = regex(#"FILED FL:? ?([0-9]{3})\b"#)

    /// `/BCNCDYA.FS1/FSM 0358 261127 LEVC\nPVG127P RCD RECEIVED\nREQUEST BEING PROCESSED`: the
    /// clearance service's status reply, shown as its own words.
    static func clearanceStatus(_ core: String) -> AcarsContent? {
        guard let m = match(statusPattern, core) else { return nil }
        var lines = core.split(separator: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        // The message ends with its four-character check sequence, on its own line or appended to the last.
        if let last = lines.last, last.count > 4, last.suffix(4).allSatisfy(\.isHexDigit) { lines[lines.count - 1] = String(last.dropLast(4)) }
        lines = lines.filter { !$0.isEmpty && $0.contains(" ") }
        guard !lines.isEmpty else { return nil }
        return AcarsContent(kind: "Clearance status",
                            summary: "\(m[3]) at \(m[1].prefix(2)):\(m[1].suffix(2))Z: \(lines.joined(separator: " · "))")
    }
    private static let statusPattern = regex(#"^/[A-Z0-9]{7}\.FS1/FSM ([0-2][0-9][0-5][0-9]) ([0-9]{6}) ([A-Z]{4})\b"#)

    /// Airline takeoff and landing performance printouts (`KTPA T/O DATA … KTPA 01L … V1 149 …
    /// VR 152 … V2 153`). Layouts vary by airline, so only the runway and the V-speeds, which are
    /// labelled, are read from takeoff data; landing data is named only.
    static func performanceData(_ core: String) -> AcarsContent? {
        let head = core.prefix(40)
        if head.contains("LDG DATA") { return AcarsContent(kind: "Landing data") }
        guard head.contains("T/O DATA") else { return nil }
        var fields: [AcarsMessage.Field] = []
        if let rw = match(takeoffRunwayPattern, core) { fields.append(.init(name: "Runway", value: "\(rw[2]) at \(rw[1])")) }
        let speeds = vSpeedPatterns.compactMap { v, re in match(re, core).map { "\(v) \($0[1]) kt" } }
        if speeds.count == 3 { fields.append(.init(name: "Speeds", value: speeds.joined(separator: ", "))) }
        return AcarsContent(kind: "Takeoff data", fields: fields)
    }
    private static let vSpeedPatterns = ["V1", "VR", "V2"].map { ($0, regex("(?m)^\\s*\($0) ([0-9]{3})\\b")) }
    private static let takeoffRunwayPattern = regex(#"(?m)^\s*([A-Z]{4}) ([0-3][0-9][LRC]?)\s"#)

    // MARK: FANS-1/A (ARINC 622)

    /// `/BNECAYA.ADS.B-5966080713…`: ground address, message type, registration and a hex body
    /// ending in a CRC-16. CPDLC bodies are named only; ADS-C downlinks have their basic report
    /// (position, altitude, time) decoded when the CRC checks out.
    static func arinc622(_ core: String, downlink: Bool) -> AcarsContent? {
        guard let m = match(arinc622Pattern, core) else { return nil }
        let imi = m[1]
        let body = Array(core.utf8.dropFirst(m[0].utf8.count))
        let kind: String
        switch imi {
        case "AT1": kind = "CPDLC message (encoded)"
        case "CR1": kind = "CPDLC connection request"
        case "CC1": kind = "CPDLC connection confirmed"
        case "DR1": kind = "CPDLC disconnection"
        case "DIS": kind = "ADS-C disconnection"
        default: kind = downlink ? "ADS-C report (encoded)" : "ADS-C contract request (encoded)"
        }
        guard imi == "ADS", downlink, let bytes = hexBytes(body), bytes.count > 2,
              CRC.arinc16(Array((imi + m[2]).utf8) + bytes) == 0x1D0F,
              let report = ADSC.basicReport(Array(bytes.dropLast(2))) else { return AcarsContent(kind: kind) }
        return AcarsContent(kind: "ADS-C \(report.title)", fields: [
            .init(name: "Position", value: describe(report.position)),
            .init(name: "Altitude", value: "\(report.altitudeFt.formatted()) ft"),
            .init(name: "Time", value: String(format: "%02d:%04.1f past the hour", Int(report.secondsPastHour) / 60,
                                              report.secondsPastHour.truncatingRemainder(dividingBy: 60))),
        ])
    }
    private static let arinc622Pattern = regex(#"^(?:[A-Z0-9]{10})?/[A-Z0-9]{7}\.(AT1|CR1|CC1|DR1|ADS|DIS)(.{7})"#)

    private static func hexBytes(_ s: [UInt8]) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            default: nil
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(s.count / 2)
        var i = 0
        while i < s.count {
            guard let hi = nibble(s[i]), let lo = nibble(s[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    // MARK: MIAM (ARINC 841)

    /// Label MA: a MIAM single transfer (`T` + CORE PDU). A data PDU's body is decoded (base85,
    /// then inflated when compressed) and must pass its CRC; printable text is shown, anything
    /// else is only named. Messages that arrived in pieces can't be decoded on their own.
    static func miam(_ core: String) -> AcarsContent? {
        guard core.first == "T", let pdu = MIAM.pdu(String(core.dropFirst())) else {
            return AcarsContent(kind: "MIAM message (part)",
                                summary: "Part of a compressed airline message; it can’t be decoded on its own.")
        }
        switch pdu {
        case .ack: return AcarsContent(kind: "MIAM acknowledgement")
        case .aloha: return AcarsContent(kind: "MIAM link setup")
        case .incomplete: return AcarsContent(kind: "MIAM message (incomplete)",
                                              summary: "A compressed airline message that wasn’t received in full.")
        case .binary(let label): return AcarsContent(kind: "Encoded airline data (binary)", fields: label.map { [.init(name: "Label", value: $0)] } ?? [])
        case .text(let label, let text, let compressed):
            var fields = label.map { [AcarsMessage.Field(name: "Label", value: $0)] } ?? []
            fields += a350Report(text)
            return AcarsContent(kind: compressed ? "MIAM compressed message" : "MIAM message", fields: fields, text: text)
        }
    }

    /// Airbus A350 condition-monitoring reports inside MIAM (`…/H02,KORD EDDM,DLH4C  ,…/H03,Normal
    /// Landing Gear Retraction/…`): the route, flight and report name.
    static func a350Report(_ text: String) -> [AcarsMessage.Field] {
        guard text.hasPrefix("A350,") else { return [] }
        var fields: [AcarsMessage.Field] = []
        if let m = match(a350RoutePattern, text) {
            fields.append(.init(name: "Route", value: "\(m[1]) → \(m[2])"))
            fields.append(.init(name: "Flight", value: m[3]))
        }
        if let m = match(a350TitlePattern, text) { fields.append(.init(name: "Report", value: m[1])) }
        return fields
    }
    private static let a350RoutePattern = regex(#"/H02,([A-Z]{4}) ([A-Z]{4}),([A-Z0-9]{3,8}) *,"#)
    private static let a350TitlePattern = regex(#"/H03,([A-Za-z][A-Za-z0-9 ()-]{2,60})/"#)

    // MARK: Helpers

    /// "42.475° N, 87.807° W (2.0 nm N of PWK)", placed with `PositionDescriber` in nautical miles.
    static func describe(_ p: GeoPoint) -> String {
        let base = AcarsDecoder.format(p)
        return PositionDescriber.location(of: p).map { "\(base) (\($0))" } ?? base
    }

    /// "03:51:13Z".
    static func utcSeconds(_ date: Date) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let d = c.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02dZ", d.hour ?? 0, d.minute ?? 0, d.second ?? 0)
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

// MARK: - ADS-C

enum ADSC {
    struct BasicReport: Equatable {
        /// "periodic report", "emergency report" or "event report".
        var title: String
        var position: GeoPoint
        var altitudeFt: Int
        /// Seconds past the hour (UTC) when the position was measured.
        var secondsPastHour: Double
    }

    /// The basic report a downlink ADS-C message starts with (tag 7 periodic, 9 emergency,
    /// 10/18/19/20 events): 21-bit latitude and longitude (MSB weight 90°), 16-bit altitude in
    /// 4 ft steps and a 15-bit time in eighths of a second past the hour.
    static func basicReport(_ bytes: [UInt8]) -> BasicReport? {
        let titles: [UInt8: String] = [7: "periodic report", 9: "emergency report", 10: "event report",
                                       18: "event report", 19: "event report", 20: "event report"]
        guard bytes.count >= 11, let title = titles[bytes[0]] else { return nil }
        var bits = BitReader(bytes: Array(bytes[1..<11]))
        func coordinate(_ raw: UInt32) -> Double {
            let signed = raw & 0x10_0000 != 0 ? Int(raw) - 0x20_0000 : Int(raw)
            return (180 - 90 / pow(2, 19)) * Double(signed) / Double(0xF_FFFF)
        }
        let lat = coordinate(bits.read(21)), lon = coordinate(bits.read(21))
        let rawAlt = bits.read(16)
        let alt = (rawAlt & 0x8000 != 0 ? Int(rawAlt) - 0x1_0000 : Int(rawAlt)) * 4
        let seconds = Double(bits.read(15)) * 0.125
        guard abs(lat) <= 90, abs(lon) <= 180, (-1_500...60_000).contains(alt), seconds < 3_600 else { return nil }
        return BasicReport(title: title, position: GeoPoint(lat: lat, lon: lon), altitudeFt: alt, secondsPastHour: seconds)
    }

    /// Reads big-endian bit fields.
    private struct BitReader {
        let bytes: [UInt8]
        var offset = 0

        mutating func read(_ count: Int) -> UInt32 {
            var v: UInt32 = 0
            for _ in 0..<count {
                let bit = bytes[offset / 8] >> (7 - UInt8(offset % 8)) & 1
                v = v << 1 | UInt32(bit)
                offset += 1
            }
            return v
        }
    }
}

// MARK: - MIAM

enum MIAM {
    enum PDU: Equatable {
        /// A data PDU whose body decoded to printable text; `label` is the ACARS label it carries ("H1/DF").
        case text(label: String?, text: String, compressed: Bool)
        /// A data PDU with a body that isn't text.
        case binary(label: String?)
        /// A data PDU whose body is missing, cut short or fails its CRC.
        case incomplete
        case ack
        /// Aloha / Aloha reply: the link's capability exchange.
        case aloha
    }

    /// Largest decompressed body accepted.
    static let maxInflated = 64 * 1024

    /// Parses a MIAM CORE PDU: body and header padding digits, the base85 header, `|`, then the
    /// body (base85 for padding 0–3, plain text for `-`, none for `.`). Nil when it isn't one.
    static func pdu(_ s: String) -> PDU? {
        let c = Array(s.utf8)
        guard c.count >= 3, let bar = c.firstIndex(of: UInt8(ascii: "|")), bar > 2 else { return nil }
        let bpad = c[0], hpad = c[1]
        guard (48...51).contains(hpad), (48...51).contains(bpad) || bpad == UInt8(ascii: "-") || bpad == UInt8(ascii: ".") else { return nil }
        guard var header = base85(Array(c[2..<bar])), header.count > Int(hpad - 48) else { return nil }
        header.removeLast(Int(hpad - 48))
        let version = header[0] & 0xF, type = header[0] >> 4
        guard version == 1 || version == 2 else { return nil }
        switch type {
        case 1: return .ack
        case 2, 3: return .aloha
        case 0: break
        default: return nil
        }
        let rest = Array(c[(bar + 1)...])
        let body: [UInt8]?
        switch bpad {
        case UInt8(ascii: "-"): body = rest
        case UInt8(ascii: "."): body = []
        default:
            body = base85(rest).flatMap { b in b.count >= Int(bpad - 48) ? Array(b.dropLast(Int(bpad - 48))) : nil }
        }
        guard let body else { return .incomplete }
        return data(header, version: version, body: body)
    }

    /// A data PDU: v1 headers carry the length and aircraft id before the message number,
    /// compression, encoding and application type; v2 headers start with the message number.
    private static func data(_ header: [UInt8], version: UInt8, body: [UInt8]) -> PDU? {
        var h = ArraySlice(header)
        if version == 1 {
            guard h.count >= 20 else { return nil }
            h = h.dropFirst(11)
        } else {
            guard h.count >= 7 else { return nil }
            h = h.dropFirst()
        }
        let b = Array(h)
        let compression = ((b[1] << 2) | (b[2] >> 6)) & 0x7
        let appType = b[2] & 0xF
        let appIDLength: Int
        switch appType {
        case 0: appIDLength = 2
        case 1: appIDLength = 4
        case 2, 3: appIDLength = 6
        case let t where version == 2 && t & 0x8 != 0 && t != 0xD: appIDLength = Int(t & 0x7) + 1
        default: return nil
        }
        let crcLength = version == 1 ? 4 : 2
        guard b.count >= 3 + appIDLength + crcLength else { return nil }
        let appID = b[3..<(3 + appIDLength)]
        let crc = b[(3 + appIDLength)..<(3 + appIDLength + crcLength)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let label: String? = appType <= 2 && appID.allSatisfy({ (32...126).contains($0) }) ? {
            let s = String(decoding: appID, as: UTF8.self)
            return appIDLength > 2 ? "\(s.prefix(2))/\(s.dropFirst(2).prefix(2))" : s
        }() : nil
        guard !body.isEmpty else { return .incomplete }
        let content: [UInt8]
        switch compression {
        case 0: content = body
        case 1:
            guard let inflated = inflateRaw(body) else { return .incomplete }
            content = inflated
        default: return .incomplete
        }
        let check = version == 1 ? CRC.arinc665(content) : UInt32(CRC.arinc16(content))
        guard check == crc else { return .incomplete }
        guard content.allSatisfy({ (7...13).contains($0) || (32...126).contains($0) }) else { return .binary(label: label) }
        let text = String(decoding: content, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        return .text(label: label, text: text, compressed: compression == 1)
    }

    /// Base85 (Ascii85, `z` for a zero word) to bytes; nil on a character outside the alphabet
    /// or a group that overflows 32 bits. A trailing partial group is ignored, as in libacars.
    static func base85(_ s: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(s.count / 5 * 4 + 4)
        var i = 0
        while i < s.count {
            var v: UInt64 = 0
            if s[i] == UInt8(ascii: "z") {
                i += 1
            } else {
                guard s.count - i >= 5 else { break }
                for k in 0..<5 {
                    let ch = s[i + k]
                    guard (33...117).contains(ch) else { return nil }
                    v = v * 85 + UInt64(ch - 33)
                }
                guard v <= UInt64(UInt32.max) else { return nil }
                i += 5
            }
            out += [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        }
        return out
    }

    /// Inflates a raw deflate stream (no zlib header), or nil if it's corrupt, cut short or
    /// larger than `maxInflated`.
    static func inflateRaw(_ input: [UInt8]) -> [UInt8]? {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        let chunk = 4_096
        var output: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: chunk)
        return input.withUnsafeBufferPointer { src -> [UInt8]? in
            stream.pointee.src_ptr = src.baseAddress!
            stream.pointee.src_size = src.count
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { dst -> compression_status in
                    stream.pointee.dst_ptr = dst.baseAddress!
                    stream.pointee.dst_size = chunk
                    return compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                output += buffer[0..<(chunk - stream.pointee.dst_size)]
                guard output.count <= maxInflated else { return nil }
                switch status {
                case COMPRESSION_STATUS_END: return output
                case COMPRESSION_STATUS_OK where stream.pointee.dst_size == 0: continue
                default: return nil   // an error, or the input ran out before the stream's end
                }
            }
        }
    }
}

// MARK: - Checksums

enum CRC {
    private static let table16: [UInt16] = (0..<256).map { i in
        (0..<8).reduce(UInt16(i) << 8) { c, _ in c & 0x8000 != 0 ? c << 1 ^ 0x1021 : c << 1 }
    }
    private static let table32: [UInt32] = (0..<256).map { i in
        (0..<8).reduce(UInt32(i) << 24) { c, _ in c & 0x8000_0000 != 0 ? c << 1 ^ 0x04C1_1DB7 : c << 1 }
    }

    /// CRC-16 as ARINC 622 and MIAM v2 use it: polynomial 0x1021, initial value 0xFFFF, not reflected.
    static func arinc16(_ data: [UInt8]) -> UInt16 {
        data.reduce(0xFFFF) { c, b in c << 8 ^ table16[Int((c >> 8) ^ UInt16(b)) & 0xFF] }
    }

    /// CRC-32 per ARINC 665 (MIAM v1): polynomial 0x04C11DB7, initial value and final XOR 0xFFFFFFFF, not reflected.
    static func arinc665(_ data: [UInt8]) -> UInt32 {
        ~data.reduce(0xFFFF_FFFF) { c, b in c << 8 ^ table32[Int((c >> 24) ^ UInt32(b))] }
    }
}
