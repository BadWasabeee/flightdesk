// Fixes and navaids for drawing routes decoded from ACARS. The table is bundled with the app
// only (the detail view is its only user) and parsed on first use, off the main thread.

import Foundation

/// A named point from the navigation table.
struct NavPoint: Equatable, Sendable {
    enum Kind: Character, Sendable {
        /// A named fix or waypoint.
        case fix = "F"
        /// A VOR, VOR-DME, VORTAC, TACAN or DME.
        case vhf = "V"
        case ndb = "N"
    }

    let ident: String
    let point: GeoPoint
    let kind: Kind
}

/// Fixes and navaids by ident, from `navdata.csv` (FAA NASR fixes and US navaids plus OurAirports'
/// worldwide navaids; see `scripts/update-navdata.sh`). Idents aren't unique worldwide, so a
/// lookup returns every candidate and `AcarsRouteResolver` picks one from the route's context.
final class NavDB: Sendable {
    private final class BundleToken {}

    /// The bundled table, loaded on first use (about 80,000 entries; empty in targets that don't bundle it).
    static let bundled: NavDB = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "navdata", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            fdLog.error("navdata.csv is missing from the bundle")
            return NavDB([])
        }
        return NavDB(csv: text)
    }()

    /// Sorted by ident, for binary search.
    private let entries: [NavPoint]

    init(_ points: [NavPoint]) {
        entries = points.sorted { $0.ident < $1.ident }
    }

    /// Parses `ident,lat,lon,kind` rows; `#` lines and malformed rows are skipped.
    convenience init(csv text: String) {
        var points: [NavPoint] = []
        points.reserveCapacity(text.utf8.count / 24)
        for line in text.split(separator: "\n") where line.first != "#" {
            let c = line.split(separator: ",", omittingEmptySubsequences: false)
            guard c.count >= 4, !c[0].isEmpty, let lat = Double(c[1]), let lon = Double(c[2]), abs(lat) <= 90, abs(lon) <= 180,
                  let k = c[3].first, let kind = NavPoint.Kind(rawValue: k) else { continue }
            points.append(NavPoint(ident: String(c[0]), point: GeoPoint(lat: lat, lon: lon), kind: kind))
        }
        self.init(points)
    }

    var count: Int { entries.count }

    /// Every entry named `ident` (uppercase), in no particular order.
    func candidates(for ident: String) -> [NavPoint] {
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].ident < ident { low = mid + 1 } else { high = mid }
        }
        var out: [NavPoint] = []
        while low < entries.count, entries[low].ident == ident {
            out.append(entries[low])
            low += 1
        }
        return out
    }
}
