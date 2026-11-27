// The full-screen radar map behind the sheet: every aircraft in range (sized by class, ringed when
// something's unusual), the search radius and your location, and for the selected aircraft its
// flown track and the route ahead. The camera only moves when you ask it to; selecting an aircraft
// at most pans it out from under the sheet, never zooms.
//
// MapKit rules learned on the Mac: no MapCircle (a polygon instead), no repeated consecutive
// vertices, no geodesic contours, and lines split at the antimeridian.

import Combine
import MapKit
import SwiftUI

struct RadarMapView: View {
    @ObservedObject var store: LiveStore
    @ObservedObject var radar: RadarModel
    @ObservedObject private var router = AppRouter.shared
    /// Republishes the open detail's changes (its track and route), which the map draws.
    @StateObject private var relay = DetailRelay()
    @State private var camera: MapCameraPosition = .automatic
    @State private var region: MKCoordinateRegion?
    @State private var mapSize: CGSize = .zero
    @State private var labelled: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var o: DisplayOptions { store.settings.display.withStandardStyle }
    private var radiusNM: Int { store.settings.radius.nm }
    private var observer: GeoPoint? { Shared.location.map { GeoPoint(lat: $0.lat, lon: $0.lon) } }
    private var framingKey: String { "\(observer.map { "\($0.lat),\($0.lon)" } ?? "")|\(radiusNM)" }
    private var motion: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.5) }
    /// The open detail, when it's for the selected aircraft.
    private var detail: FlightDetailModel? { radar.detail.flatMap { $0.hex == radar.selection ? $0 : nil } }

    var body: some View {
        ZStack {
            map
                .ignoresSafeArea()
            // Overlays stay inside the safe area (clear of the clock and Dynamic Island).
            VStack {
                MapStatusBanner(feed: radar.feed, hasFlights: !radar.flights.isEmpty, radius: o.radius(radiusNM))
                    .padding(.top, 4)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) { controls }
        }
    }

    private var map: some View {
        let selected = radar.selected.flatMap { s in radar.flights.first { $0.id == s.id } ?? s }
        return Map(position: $camera, interactionModes: [.pan, .zoom, .rotate]) {
            if let observer { searchArea(observer) }
            if let selected {
                if let detail { detailPaths(detail) } else { radarPaths(selected) }
                airports(for: detail?.flight ?? selected, detail: detail)
            }
            ForEach(radar.flights.filter { $0.id != selected?.id }) { aircraft($0, selected: false) }
            if let selected { aircraft(selected, selected: true) }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            region = context.region
            radar.mapRegion = context.region
            relabel()
        }
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            mapSize = size
            relabel()
        }
        .onAppear { relay.bind(radar) }
        .onChange(of: framingKey, initial: true) {
            guard radar.framedKey != framingKey else { return }
            radar.framedKey = framingKey
            frameNearby(animated: radar.mapRegion != nil)
        }
        .onChange(of: radar.flights) { relabel() }
        .onChange(of: radar.selection) { _, id in
            relabel()
            reveal(id)
        }
        .onReceive(router.mapCommands) { command in
            switch command {
            case .wholeFlight: frameFlight()
            case .aircraft: frameAircraft()
            case .nearby: frameNearby(animated: true)
            }
        }
    }

    // MARK: Content

    @MapContentBuilder
    private func searchArea(_ observer: GeoPoint) -> some MapContent {
        // A polygon, not MapCircle: MapCircle stops the map rendering tiles while on screen.
        MapPolygon(coordinates: FlightMath.removingRepeats(FlightMath.circle(around: observer, radiusNM: Double(radiusNM)))
            .map(\.coordinate))
            .foregroundStyle(Color.blue.opacity(0.05))
            .stroke(Color.blue.opacity(0.55), lineWidth: 1.5)
        Annotation("", coordinate: CLLocationCoordinate2D(latitude: observer.lat + Double(radiusNM) / 60, longitude: observer.lon),
                   anchor: .center) {
            Text(o.radius(radiusNM))
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.blue.opacity(0.85)))
                .accessibilityLabel("Search radius \(o.radius(radiusNM))")
        }
        .annotationTitles(.hidden)
        Annotation("You", coordinate: observer.coordinate, anchor: .center) {
            Circle()
                .fill(Color.blue)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(.white, lineWidth: 2.5))
                .shadow(color: .black.opacity(0.3), radius: 2)
                .accessibilityLabel("Your location")
        }
        .annotationTitles(.hidden)
    }

    /// The selected aircraft without a detail open: its recorded track and live trail, and dashes
    /// along the route ahead (as the Mac radar draws it).
    @MapContentBuilder
    private func radarPaths(_ f: Flight) -> some MapContent {
        ForEach(Array(RouteGeometry.antimeridianSafe(aheadPath(of: f)).enumerated()), id: \.offset) { _, line in
            if line.count > 1 {
                MapPolyline(coordinates: line.map(\.coordinate))
                    .stroke(Color.black.opacity(0.3), style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [7, 7]))
                MapPolyline(coordinates: line.map(\.coordinate))
                    .stroke(Color.accentColor.opacity(0.75), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [7, 7]))
            }
        }
        let flown = FlightMath.removingRepeats(radar.tracks[f.id, default: []] + radar.trail + [f.geoPoint])
        ForEach(Array(RouteGeometry.antimeridianSafe(flown).enumerated()), id: \.offset) { _, line in
            if line.count > 1 {
                MapPolyline(coordinates: line.map(\.coordinate))
                    .stroke(Color.black.opacity(0.3), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: line.map(\.coordinate))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// With the detail open: the detail's own paths (recorded track, ACARS route, runway), as its Mac map draws them.
    @MapContentBuilder
    private func detailPaths(_ d: FlightDetailModel) -> some MapContent {
        ForEach(Array(d.remainingLines.enumerated()), id: \.offset) { _, line in
            if line.count > 1 {
                MapPolyline(coordinates: line.map(\.coordinate))
                    .stroke(Color.black.opacity(0.4), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: line.map(\.coordinate))
                    .stroke(Color.accentColor.opacity(d.destinationEstimated ? 0.65 : 1),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [6, 8]))
            }
        }
        ForEach(Array(d.headingLines.enumerated()), id: \.offset) { _, line in
            if line.count > 1 {
                MapPolyline(coordinates: line.map(\.coordinate))
                    .stroke(Color.accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.5, 5]))
            }
        }
        if d.runwayHighlight.centreline.count > 1 {
            MapPolyline(coordinates: d.runwayHighlight.centreline.map(\.coordinate))
                .stroke(Color.primary.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
        if d.runwayHighlight.runway.count > 1 {
            MapPolyline(coordinates: d.runwayHighlight.runway.map(\.coordinate))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 9, lineCap: .butt))
            MapPolyline(coordinates: d.runwayHighlight.runway.map(\.coordinate))
                .stroke(Color(white: 0.25), style: StrokeStyle(lineWidth: 6, lineCap: .butt))
        }
        ForEach(Array(d.flownLines.enumerated()), id: \.offset) { _, line in
            if line.count > 1 {
                MapPolyline(coordinates: line.map(\.coordinate))
                    .stroke(Color.black.opacity(0.25), style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: line.map(\.coordinate))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
        }
        if DetailFormat.MapDetail(latitudeSpan: region?.span.latitudeDelta ?? 180) == .labelled {
            ForEach(d.waypointMarks) { w in
                Annotation("", coordinate: w.point.coordinate, anchor: .center) {
                    WaypointMarker(label: w.label, showLabel: labelled.contains(w.id))
                }
                .annotationTitles(.hidden)
            }
        }
    }

    /// Origin and destination (a diversion strikes the scheduled destination through).
    @MapContentBuilder
    private func airports(for f: Flight, detail: FlightDetailModel?) -> some MapContent {
        if let r = f.route {
            airport(r.from, role: "Departure")
            if let s = f.pathSituation, let to = s.newDestination {
                airport(r.to, role: "Scheduled destination", struck: true)
                if to.code != r.from.code { airport(to, role: s.headline) }
            } else {
                airport(r.to, role: detail?.destinationEstimated == true ? "Estimated destination" : "Destination")
            }
        } else if let origin = detail?.departedFrom {
            airport(origin, role: "Departure")
        }
    }

    private func airport(_ a: Airport, role: String, struck: Bool = false) -> some MapContent {
        Annotation("", coordinate: a.geoPoint.coordinate, anchor: .center) {
            VStack(spacing: 2) {
                Circle()
                    .fill(Color.platformBackground)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2.5))
                Text(a.code)
                    .font(.system(size: 12, weight: .bold))
                    .strikethrough(struck)
                    .foregroundStyle(.primary)
                    .shadow(color: Color.platformBackground, radius: 1.5)
                    .shadow(color: Color.platformBackground, radius: 1.5)
            }
            .opacity(struck ? 0.55 : 1)
            .offset(y: 8)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(role) airport, \(a.code)\(a.city.isEmpty ? "" : ", \(a.city)")")
        }
        .annotationTitles(.hidden)
    }

    private func aircraft(_ f: Flight, selected: Bool) -> some MapContent {
        Annotation(f.displayNumber, coordinate: f.geoPoint.coordinate, anchor: .center) {
            AircraftMarker(f: f, selected: selected, showsLabel: selected || labelled.contains(f.id))
                // A comfortable touch target around small icons.
                .padding(4)
                .contentShape(Rectangle())
                .onTapGesture { router.showFlight(hex: f.id, snapshot: f) }
                .accessibilityAction { router.showFlight(hex: f.id, snapshot: f) }
        }
        .annotationTitles(.hidden)
    }

    /// The route ahead: along the decoded ACARS route when one is known (not while diverting),
    /// else a great circle to the destination.
    private func aheadPath(of f: Flight) -> [GeoPoint] {
        if let route = radar.acarsRoutes[f.id], f.pathSituation?.newDestination == nil,
           let plan = route.plan(aircraft: f.geoPoint, origin: f.route?.from.geoPoint, destination: f.route?.to.geoPoint) {
            return FlightMath.removingRepeats(plan.remaining)
        }
        guard f.route != nil, let to = f.destination else { return [] }
        return FlightMath.removingRepeats(FlightMath.greatCircle(from: f.geoPoint, to: to.geoPoint))
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 0) {
            // The detail's framing buttons are in the sheet's toolbar, next to the flight.
            if observer != nil {
                mapButton("Show Flights Near You", "location.fill") { frameNearby(animated: true) }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        // Clear of the compass, which MapKit puts in the top trailing corner.
        .padding(.top, 52)
        .padding(.trailing, 10)
    }

    private func mapButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel(title)
    }

    // MARK: Camera

    /// The share of the map hidden by the sheet, at the height it has (or is about to have).
    private var obscured: Double {
        guard mapSize.height > 0 else { return 0.5 }
        let sheet = router.detent == .large || router.detent == .medium ? max(router.sheetHeight, mapSize.height * 0.5)
            : router.sheetHeight
        return min(0.8, Double(min(sheet, mapSize.height * 0.55) / mapSize.height))
    }

    private func viewport(_ r: MKCoordinateRegion) -> MapReveal.Viewport {
        MapReveal.Viewport(center: GeoPoint(lat: r.center.latitude, lon: r.center.longitude),
                           latitudeDelta: r.span.latitudeDelta, longitudeDelta: r.span.longitudeDelta, obscuredBottom: obscured)
    }

    /// Pans (keeping the zoom) to a newly selected aircraft when it's off screen or under the sheet.
    private func reveal(_ id: Flight.ID?) {
        guard let id, let f = radar.flights.first(where: { $0.id == id }), let r = region,
              let center = MapReveal.center(revealing: f.geoPoint, in: viewport(r)) else { return }
        move(MKCoordinateRegion(center: center.coordinate, span: r.span))
    }

    private func frameNearby(animated: Bool) {
        guard let observer else { return }
        let v = MapReveal.framing(around: observer, radiusNM: Double(radiusNM), obscuredBottom: obscured)
        move(region(v), animated: animated)
    }

    /// The aircraft about 60 nm across, in the middle of the uncovered map.
    private func frameAircraft() {
        guard let f = detail?.flight ?? radar.selected else { return }
        var v = MapReveal.Viewport(center: f.geoPoint, latitudeDelta: 1, longitudeDelta: 1 / max(0.2, cos(f.lat * .pi / 180)),
                                   obscuredBottom: obscured)
        v.latitudeDelta /= v.visibleFraction
        v.center = GeoPoint(lat: f.lat - MapReveal.offset(v), lon: f.lon)
        move(region(v))
    }

    /// Fits origin, destination, the recorded track and the aircraft into the uncovered map
    /// (only when asked: long-haul routes never zoom the map out by themselves).
    private func frameFlight() {
        guard let d = detail, let f = d.flight else { return }
        var points = [f.geoPoint] + d.plannedPath + d.history.map(\.point)
        if let origin = d.departedFrom { points.append(origin.geoPoint) }
        if f.route == nil, let observer, FlightService.gcDistance(observer.lat, observer.lon, f.lat, f.lon) < 300 {
            points.append(observer)
        }
        guard let fr = DetailFormat.framing(points) else { return }
        var v = MapReveal.Viewport(center: fr.center, latitudeDelta: fr.latitudeDelta, longitudeDelta: fr.longitudeDelta,
                                   obscuredBottom: obscured)
        v.latitudeDelta = min(170, v.latitudeDelta / v.visibleFraction)
        v.center = GeoPoint(lat: fr.center.lat - MapReveal.offset(v), lon: fr.center.lon)
        move(region(v))
    }

    private func region(_ v: MapReveal.Viewport) -> MKCoordinateRegion {
        MKCoordinateRegion(center: v.center.coordinate,
                           span: MKCoordinateSpan(latitudeDelta: v.latitudeDelta, longitudeDelta: v.longitudeDelta))
    }

    private func move(_ r: MKCoordinateRegion, animated: Bool = true) {
        if animated, let motion { withAnimation(motion) { camera = .region(r) } } else { camera = .region(r) }
    }

    /// Picks which aircraft get labels for the current camera, keeping the previous ones where possible.
    private func relabel() {
        guard let r = region, mapSize.width > 0, mapSize.height > 0 else {
            labelled = radar.selection.map { [$0] } ?? []
            return
        }
        let vp = MapLabelLayout.Viewport(center: GeoPoint(lat: r.center.latitude, lon: r.center.longitude),
                                         latitudeDelta: r.span.latitudeDelta, longitudeDelta: r.span.longitudeDelta, size: mapSize)
        var items = radar.flights.sorted { $0.distance < $1.distance }
            .map { MapLabelLayout.Item(id: $0.id, point: $0.geoPoint, text: $0.displayNumber) }
        items += (detail?.waypointMarks ?? []).map { MapLabelLayout.Item(id: $0.id, point: $0.point, text: $0.label) }
        let next = MapLabelLayout.labelled(items, in: vp, pinned: radar.selection, prefer: labelled)
        if next != labelled { labelled = next }
    }
}

/// Forwards the radar's open detail model's changes, so the map redraws as its track and route load.
@MainActor
final class DetailRelay: ObservableObject {
    private var outer: AnyCancellable?
    private var inner: AnyCancellable?

    func bind(_ radar: RadarModel) {
        guard outer == nil else { return }
        outer = radar.$detail.sink { [weak self] detail in
            self?.inner = detail?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            self?.objectWillChange.send()
        }
    }
}
