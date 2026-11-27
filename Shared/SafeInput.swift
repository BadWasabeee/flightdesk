// Validation for identifiers that arrive from the network (feeds, deep links, notifications)
// and safe construction of URLs that embed them. Compiled into every target.

import Foundation

/// Aircraft and flight identifiers, checked before they are used in URLs, file names or UI routing.
enum AircraftID {
    /// The lowercase ICAO 24-bit address in `raw` — exactly six ASCII hex digits — or nil.
    /// With `allowNonICAO`, a leading `~` (non-ICAO / TIS-B address, as readsb reports them)
    /// is accepted and kept. Matches `^~?[0-9a-f]{6}$` after lowercasing.
    static func hex(_ raw: String, allowNonICAO: Bool = true) -> String? {
        let s = raw.lowercased()
        let body = allowNonICAO && s.hasPrefix("~") ? s.utf8.dropFirst() : Substring(s).utf8
        guard body.count == 6, body.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return nil }
        return s
    }

    /// The uppercase callsign in `raw` (surrounding spaces ignored) when it is 2–8 ASCII letters
    /// and digits (`^[A-Z0-9]{2,8}$`), else nil.
    static func callsign(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard (2...8).contains(s.utf8.count),
              s.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }) else { return nil }
        return s
    }
}

/// Builds URLs from a fixed, trusted base and untrusted path segments or query values, so remote
/// strings can never add path components, queries or fragments.
enum RemoteURL {
    /// RFC 3986 unreserved characters; everything else is percent-encoded.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encodes `value` for use as one path segment or query value. Nil for empty, `.` or `..`.
    static func encode(_ value: String) -> String? {
        guard !value.isEmpty, value != ".", value != ".." else { return nil }
        return value.addingPercentEncoding(withAllowedCharacters: unreserved)
    }

    /// `base` (a constant `https://host/path` string) with each of `segments` appended as a single,
    /// fully encoded path segment, and `query` appended in order with encoded names and values.
    static func make(_ base: String, _ segments: [String] = [], query: [(String, String)] = []) -> URL? {
        guard var c = URLComponents(string: base), c.scheme == "https", c.host?.isEmpty == false,
              c.query == nil, c.fragment == nil else { return nil }
        var path = c.percentEncodedPath
        while !segments.isEmpty, path.hasSuffix("/") { path.removeLast() }
        for s in segments {
            guard let e = encode(s) else { return nil }
            path += "/" + e
        }
        c.percentEncodedPath = path
        if !query.isEmpty {
            var items: [URLQueryItem] = []
            for (name, value) in query {
                guard let n = encode(name), let v = value.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
                items.append(URLQueryItem(name: n, value: v))
            }
            c.percentEncodedQueryItems = items
        }
        return c.url
    }
}

/// Airport identifiers, checked before they are sent to a weather service.
enum AirportCode {
    /// The uppercase ICAO location indicator in `raw` (surrounding spaces ignored): a letter then
    /// three ASCII letters or digits (`^[A-Z][A-Z0-9]{3}$`), else nil.
    static func icao(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        let u = Array(s.utf8)
        guard u.count == 4, (0x41...0x5A).contains(u[0]),
              u.dropFirst().allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }) else { return nil }
        return s
    }
}
