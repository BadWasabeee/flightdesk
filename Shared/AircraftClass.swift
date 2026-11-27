import Foundation

/// Rough size class of an aircraft from its ICAO type designator, used to scale map icons.
enum AircraftClass: Equatable {
    case wideBody, narrowBody, regional, light, rotorcraft

    init(typeCode: String) {
        let t = typeCode.uppercased()
        func starts(_ prefixes: [String]) -> Bool { prefixes.contains { t.hasPrefix($0) } }
        if starts(["A30", "A31", "A33", "A34", "A35", "A38", "B74", "B76", "B77", "B78", "MD11", "DC10",
                   "IL96", "A124", "A225", "KC10", "KC46", "B52", "A400"]) || ["C5M", "C17"].contains(t) {
            self = .wideBody
        } else if starts(["A19N", "A20N", "A21N", "A318", "A319", "A320", "A321", "B73", "B75", "B38M", "B39M",
                          "B37M", "B3XM", "BCS", "MD8", "MD9", "B71", "B72", "C919", "E29", "E19", "E195",
                          "TU", "SU95", "C130", "C30J", "P8", "E3CF", "E3TF"]) {
            self = .narrowBody
        } else if starts(["CRJ", "E13", "E14", "E17", "E75", "E45", "E35", "AT4", "AT7", "DH8", "SF34", "SB20",
                          "F70", "F100", "RJ", "B46", "J328", "D328", "Q4", "AN2", "SW4", "B190", "JS4"]) {
            self = .regional
        } else if starts(["H", "EC", "AS", "R22", "R44", "R66", "B06", "B407", "B412", "B429", "S76", "S92",
                          "A109", "A119", "A139", "A169", "A189", "MD5", "MD6", "UH", "BK17"]) && !t.hasPrefix("HDJT") {
            self = .rotorcraft
        } else {
            self = .light
        }
    }

    /// Icon scale relative to a narrow-body.
    var iconScale: Double {
        switch self {
        case .wideBody: 1.35
        case .narrowBody: 1
        case .regional: 0.82
        case .light: 0.66
        case .rotorcraft: 0.66
        }
    }

    /// SF Symbol for the class (rotorcraft use a distinct symbol so they don't read as planes).
    var symbol: String { self == .rotorcraft ? "fanblades.fill" : "airplane" }
}
