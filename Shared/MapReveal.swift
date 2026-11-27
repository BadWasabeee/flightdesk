// Camera math for a map partly covered by a bottom sheet (the iPhone radar). Selecting an aircraft
// only ever pans, never zooms; framing the search area fits it in the part of the map you can see.
// Pure Foundation so it can be unit tested.

import Foundation

enum MapReveal {
    /// The visible map: centre and span in degrees, and the fraction of its height (from the bottom)
    /// hidden under the sheet.
    struct Viewport: Equatable {
        var center: GeoPoint
        var latitudeDelta: Double
        var longitudeDelta: Double
        var obscuredBottom: Double = 0

        /// The share of the height that's uncovered, never below 20 % (a nearly closed sheet aside).
        var visibleFraction: Double { max(0.2, 1 - min(max(obscuredBottom, 0), 0.8)) }
    }

    /// Where to move the centre so `point` sits in the middle of the uncovered area, keeping the
    /// zoom; nil when it's already comfortably visible (inside `margin` of the uncovered edges).
    static func center(revealing point: GeoPoint, in v: Viewport, margin: Double = 0.08) -> GeoPoint? {
        let top = v.center.lat + v.latitudeDelta / 2
        let bottom = top - v.latitudeDelta * v.visibleFraction
        let insetLat = v.latitudeDelta * margin, insetLon = v.longitudeDelta * margin
        let dLon = wrapped(point.lon - v.center.lon)
        let inside = point.lat <= top - insetLat && point.lat >= bottom + insetLat
            && abs(dLon) <= v.longitudeDelta / 2 - insetLon
        guard !inside else { return nil }
        return GeoPoint(lat: clampLat(point.lat - offset(v)), lon: wrapped(point.lon))
    }

    /// The camera that fits a circle of `radiusNM` around `observer` (plus `padding`) into the
    /// uncovered part of a map with `obscuredBottom` hidden, centred in it.
    static func framing(around observer: GeoPoint, radiusNM: Double, obscuredBottom: Double,
                        padding: Double = 1.15) -> Viewport {
        var v = Viewport(center: observer, latitudeDelta: 0, longitudeDelta: 0, obscuredBottom: obscuredBottom)
        let d = radiusNM / 60 * padding * 2
        // The uncovered area must be `d` tall, so the whole map is taller by 1 / visibleFraction.
        v.latitudeDelta = min(170, d / v.visibleFraction)
        v.longitudeDelta = min(360, d / max(0.2, cos(observer.lat * .pi / 180)))
        v.center = GeoPoint(lat: clampLat(observer.lat - offset(v)), lon: observer.lon)
        return v
    }

    /// How far the middle of the uncovered area sits above the map's centre, in degrees of latitude.
    static func offset(_ v: Viewport) -> Double { v.latitudeDelta * (1 - v.visibleFraction) / 2 }

    private static func wrapped(_ lon: Double) -> Double {
        var l = lon.truncatingRemainder(dividingBy: 360)
        if l > 180 { l -= 360 } else if l < -180 { l += 360 }
        return l
    }

    private static func clampLat(_ lat: Double) -> Double { min(85, max(-85, lat)) }
}
