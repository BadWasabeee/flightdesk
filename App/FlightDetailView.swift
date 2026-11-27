import SwiftUI
import MapKit

// MARK: - Model

/// Live state for one aircraft's detail view. Polls adsb.lol while running and keeps the
/// last known data when the aircraft stops being reported.
@MainActor
final class FlightDetailModel: ObservableObject {
    let hex: String
    /// Unit formatters from the user's settings, in the system (non-LED) style.
    let display: DisplayOptions

    @Published private(set) var flight: Flight? { didSet { updatePaths() } }
    @Published private(set) var squawk: String?
    @Published private(set) var onGround = false { didSet { if onGround != oldValue { updatePaths() } } }
    /// True while the latest poll returned a fresh position.
    @Published private(set) var isLive = false { didSet { if isLive != oldValue { updatePaths() } } }
    /// When the most recent position was received, once a poll has returned one.
    @Published private(set) var lastSeen: Date?
    /// Positions observed while the view has been showing this aircraft, oldest first.
    @Published private(set) var trail: [TimedPoint] = [] { didSet { updatePaths() } }
    /// The flight's recorded track from OpenSky, when available.
    @Published private(set) var history: [TimedPoint] = [] { didSet { updatePaths() } }
    /// Departure airport read from the start of the recorded track.
    @Published private(set) var departedFrom: Airport?
    /// When the recorded track left `departedFrom`.
    @Published private(set) var departureTime: Date?
    /// How the shown route was worked out, when it isn't the verified scheduled route.
    @Published private(set) var routeNote: String?
    /// True when the destination is a guess from the aircraft's descent.
    @Published private(set) var destinationEstimated = false
    /// Other aircraft within the user's search radius.
    @Published private(set) var nearby: [Flight] = []
    /// The airframe photo, while loading and once found.
    @Published private(set) var photo: PhotoState = .loading(aspectRatio: 1.5)
    /// Year the airframe was built, when the live feed knows it.
    @Published private(set) var buildYear: Int?

    /// Planned great-circle route, origin to destination (cached; recomputed when data changes).
    private(set) var plannedPath: [GeoPoint] = []
    /// Flown track (cached): the recorded track plus live positions since.
    private(set) var flownPath: [GeoPoint] = []
    /// What's drawn, split at the antimeridian: the flown track, the planned route still ahead
    /// of the aircraft, and (when the route is unknown) a short vector along its heading.
    private(set) var flownLines: [[GeoPoint]] = []
    private(set) var remainingLines: [[GeoPoint]] = []
    private(set) var headingLines: [[GeoPoint]] = []

    /// Progress of the airframe photo lookup.
    enum PhotoState {
        /// Still looking; space is reserved at this width ÷ height.
        case loading(aspectRatio: Double)
        case loaded(AircraftPhoto, NSImage)
        /// No photo exists or it couldn't be loaded; nothing is shown.
        case unavailable
    }
    /// The user's search radius, drawn around their location.
    let radiusNM: Int
    private let includeGA: Bool

    private static let pollInterval: Duration = .seconds(8)
    /// A full per-aircraft report has been received (extras like the build year are known).
    private var hadFullReport = false
    private static let nearbyInterval: Duration = .seconds(15)
    /// OpenSky's anonymous quota is small, so the recorded track is refreshed sparingly.
    private static let historyInterval: Duration = .seconds(180)
    /// A position older than this counts as no longer live.
    private static let staleAfter: TimeInterval = 60

    /// Route from the lookup cache, re-verified against every live position.
    private var candidateRoute: RouteInfo?
    private var aircraftInfo: AircraftInfo?
    private var enrichedCallsign: String?
    private var tasks: [Task<Void, Never>] = []
    private var lastPlannedKey = ""

    /// `nearby` seeds the map's other aircraft (when switching planes) until the next refresh.
    init(hex: String, snapshot: Flight?, nearby: [Flight] = []) {
        self.hex = hex.lowercased()
        self.nearby = nearby.filter { $0.id != hex.lowercased() }
        let settings = AppSettings.load()
        var display = settings.display
        display.style = .standard
        self.display = display
        radiusNM = settings.radius.nm
        includeGA = settings.includeGA
        flight = snapshot
        candidateRoute = snapshot?.route
        aircraftInfo = snapshot?.aircraft
        squawk = snapshot?.squawk
        isLive = snapshot != nil
        // The snapshot can be minutes old, so it only stands in until the first live position.
        if let snapshot { trail = [TimedPoint(point: snapshot.geoPoint, time: .distantPast)] }
        updatePaths()
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }

    var isRunning: Bool { !tasks.isEmpty }

    /// Starts polling. Safe to call repeatedly.
    func start() {
        guard tasks.isEmpty else { return }
        tasks.append(Self.loop(every: Self.pollInterval) { [weak self] in await self?.poll() != nil })
        tasks.append(Self.loop(every: Self.nearbyInterval) { [weak self] in await self?.pollNearby() != nil })
        tasks.append(Self.loop(every: Self.historyInterval, delay: .seconds(1)) { [weak self] in await self?.pollHistory() != nil })
        if case .loading = photo {
            tasks.append(Task { [weak self] in await self?.loadPhoto() })
        }
    }

    /// Stops all polling. Any request already in flight is discarded when it returns.
    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    /// Runs `body` repeatedly until cancelled or until it returns false (the model is gone).
    private static func loop(every interval: Duration, delay: Duration? = nil,
                             _ body: @escaping @MainActor () async -> Bool) -> Task<Void, Never> {
        Task { @MainActor in
            if let delay { try? await Task.sleep(for: delay) }
            while !Task.isCancelled {
                guard await body() else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Looks up the airframe photo (by hex, then registration) and downloads the image.
    private func loadPhoto() async {
        // Give the first live poll a moment to supply the registration for the fallback lookup.
        if flight == nil || flight?.reg == hex.uppercased() { try? await Task.sleep(for: .seconds(1)) }
        guard !Task.isCancelled else { return }
        guard let found = await AircraftPhotos.shared.photo(hex: hex, registration: flight?.reg) else {
            if !Task.isCancelled { photo = .unavailable }
            return
        }
        guard !Task.isCancelled else { return }
        photo = .loading(aspectRatio: found.aspectRatio)
        if let data = await AircraftPhotos.shared.imageData(for: found),
           let image = await Self.decodePhoto(data) {
            if !Task.isCancelled { photo = .loaded(found, image) }
        } else if !Task.isCancelled {
            photo = .unavailable
        }
    }

    /// Decodes a downloaded photo off the main thread, checked against `ImageGuard.photo` and
    /// downscaled to at most 1200 px.
    private nonisolated static func decodePhoto(_ data: Data) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let cg = ImageGuard.thumbnail(data, ImageGuard.photo, maxPixel: 1200) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
    }

    private func pollNearby() async {
        guard let loc = Shared.location,
              let list = try? await FlightService.nearby(lat: loc.lat, lon: loc.lon, radiusNM: radiusNM,
                                                         includeGA: includeGA, limit: 250, enrich: 0),
              !Task.isCancelled else { return }
        nearby = list.filter { $0.id != hex }
    }

    private func pollHistory() async {
        guard let track = await FlightDetailService.track(hex: hex, current: flight?.geoPoint),
              !Task.isCancelled else { return }
        history = track.points
        // A track that starts low began at the departure airport.
        if let start = track.points.first, (track.startAltitudeFt ?? .infinity) < 3_000 {
            departedFrom = AirportDB.nearest(to: start.point, within: 8)
            departureTime = departedFrom == nil ? nil : start.time
        }
        if var f = flight {
            resolveRoute(&f)
            flight = f
        }
    }

    /// Picks the route to show: the scheduled route when it fits the live position (and the
    /// recorded departure airport), else what the recorded track and descent imply.
    private func resolveRoute(_ f: inout Flight) {
        routeNote = nil
        destinationEstimated = false
        let scheduled = candidateRoute
        if let r = scheduled, FlightService.isPlausible(r, for: f), departedFrom == nil || departedFrom?.code == r.from.code {
            f.route = r
            return
        }
        guard let origin = departedFrom else {
            f.route = nil
            return
        }
        if let r = scheduled, r.from.code == origin.code {
            f.route = r
            routeNote = "Origin confirmed by the recorded track."
        } else if let dest = AirportDB.likelyDestination(for: f), dest.code != origin.code {
            f.route = RouteInfo(airline: scheduled?.airline, flightNo: scheduled?.flightNo,
                                airlineCode: scheduled?.airlineCode, from: origin, to: dest)
            destinationEstimated = true
            routeNote = "No scheduled route. Origin from the recorded track; destination estimated from the descent."
        } else {
            f.route = nil
            routeNote = "No scheduled route. Origin from the recorded track."
        }
    }

    private func poll() async {
        let report: AircraftReport?
        do {
            // After one full report, a fresh shared nearby list can answer without a request.
            report = try await FlightDetailService.report(hex: hex, preferCache: hadFullReport)
        } catch {
            fdLog.info("Detail poll for \(self.hex, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            // Don't claim "Live" forever while the network is down.
            if let seen = lastSeen, -seen.timeIntervalSinceNow > Self.staleAfter { isLive = false }
            return
        }
        guard !Task.isCancelled else { return }
        guard let report else {
            isLive = false
            return
        }

        var f = report.flight
        if f.callsign != enrichedCallsign {
            let previous = enrichedCallsign ?? flight?.callsign
            enrichedCallsign = f.callsign
            let lookup = await FlightDetailService.enrichment(for: f)
            guard !Task.isCancelled else { return }
            // Keep the snapshot's route if a lookup fails for the same callsign.
            if lookup.route != nil || previous != f.callsign { candidateRoute = lookup.route }
            aircraftInfo = lookup.aircraft ?? aircraftInfo
        }
        f.aircraft = AircraftInfo(model: aircraftInfo?.model ?? f.aircraft?.model,
                                  owner: aircraftInfo?.owner ?? f.aircraft?.owner)
        resolveRoute(&f)

        var newTrail = trail.filter { $0.time != .distantPast }
        let moved = newTrail.last.map { FlightService.gcDistance($0.point.lat, $0.point.lon, f.lat, f.lon) >= 0.05 } ?? true
        if moved { newTrail.append(TimedPoint(point: f.geoPoint, time: report.positionTime)) }
        if newTrail != trail { trail = newTrail }
        flight = f
        squawk = report.squawk
        onGround = report.onGround
        lastSeen = report.positionTime
        buildYear = report.year ?? buildYear
        hadFullReport = true
        isLive = -report.positionTime.timeIntervalSinceNow < Self.staleAfter
    }

    // MARK: Derived values

    /// Title for a host window or navigation bar: the flight number (or callsign/registration).
    static func title(for f: Flight?, hex: String) -> String { DetailFormat.title(for: f, hex: hex) }

    /// Subtitle for a host: "LAS → MKE · Southwest Airlines" (may be empty).
    static func subtitle(for f: Flight?) -> String { DetailFormat.subtitle(for: f) }

    var title: String { Self.title(for: flight, hex: hex) }
    var subtitle: String { Self.subtitle(for: flight) }

    var flownNM: Double? {
        guard let f = flight, let r = f.route else { return nil }
        return FlightService.gcDistance(r.from.lat, r.from.lon, f.lat, f.lon)
    }

    var remainingNM: Double? {
        guard let f = flight, let r = f.route else { return nil }
        return FlightService.gcDistance(f.lat, f.lon, r.to.lat, r.to.lon)
    }

    /// Arrival state while live: landed, landing, or an estimate at the current ground speed.
    var arrival: DetailFormat.Arrival? {
        guard isLive, let f = flight, let left = remainingNM else { return nil }
        return DetailFormat.arrival(remainingNM: left, speedKT: f.speed, altitudeFt: f.altitude,
                                    verticalRate: f.verticalRate, onGround: onGround)
    }

    private func updatePaths() {
        let r = flight?.route
        let key = r.map { "\($0.from.code)>\($0.to.code)" } ?? ""
        if key != lastPlannedKey {
            lastPlannedKey = key
            plannedPath = r.map { FlightMath.removingRepeats(FlightMath.greatCircle(from: $0.from.geoPoint, to: $0.to.geoPoint)) } ?? []
        }
        // Merge by time so the line always runs through the aircraft's current position.
        let end = history.last?.time ?? .distantPast
        var points = history.map(\.point) + trail.filter { $0.time > end }.map(\.point)
        if let f = flight, points.last != f.geoPoint { points.append(f.geoPoint) }
        // Without a recorded track, join the origin to the first observed position.
        if history.isEmpty, let r, let first = points.first {
            points = FlightMath.greatCircle(from: r.from.geoPoint, to: first).dropLast() + points
        }
        flownPath = FlightMath.removingRepeats(points)
        flownLines = RouteGeometry.antimeridianSafe(flownPath)

        // The flown part of the route is shown by the track, so only what's ahead is dashed.
        if let f = flight, r != nil {
            remainingLines = RouteGeometry.antimeridianSafe(RouteGeometry.split(plannedPath, at: f.geoPoint).remaining)
        } else {
            remainingLines = []
        }
        if let f = flight, r == nil, isLive, !onGround, let track = f.track {
            headingLines = RouteGeometry.antimeridianSafe(RouteGeometry.headingVector(from: f.geoPoint, track: track, speedKT: f.speed))
        } else {
            headingLines = []
        }
    }

    var adsbLolURL: URL? {
        AircraftID.hex(hex).flatMap { RemoteURL.make("https://adsb.lol/", query: [("icao", $0)]) }
    }

    /// The photo's page, or a Planespotters search for the registration.
    var planespottersURL: URL? {
        if case .loaded(let p, _) = photo { return p.pageURL }
        guard let reg = flight?.reg.trimmingCharacters(in: .whitespaces), !reg.isEmpty,
              reg.uppercased() != hex.uppercased() else { return nil }
        return RemoteURL.make("https://www.planespotters.net/search", query: [("q", reg)])
    }

    /// Where to look for the aircraft from the user's location, while it's airborne.
    var skyPosition: SkyPosition? {
        guard let f = flight, !onGround, let loc = Shared.location else { return nil }
        return SkyPosition(observer: GeoPoint(lat: loc.lat, lon: loc.lon), aircraft: f.geoPoint, altitudeFt: Double(f.altitude))
    }
}

private extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

private func observerPoint() -> GeoPoint? { Shared.location.map { GeoPoint(lat: $0.lat, lon: $0.lon) } }

// MARK: - Content

/// Map plus info sidebar for one aircraft. Embeddable in any host (a window or the main
/// window's content area): it has no toolbar or window-title dependencies.
///
/// Hosts can swap `model` in place (no `.id`) for the smoothest switch: the map stays and
/// glides to the new flight, and the sidebar crossfades. The host owns `start()`/`stop()`.
struct FlightDetailView: View {
    @ObservedObject var model: FlightDetailModel
    @State private var camera: MapCameraPosition = .automatic
    @State private var latitudeSpan: Double = 180
    /// The map's camera as last reported, so a switch can keep the user's zoom level.
    @State private var visibleCamera: MapCamera?
    /// The aircraft the camera last centred on by itself (nil until the opening view is set).
    @State private var centredHex: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            FlightDetailMap(model: model, camera: $camera, latitudeSpan: $latitudeSpan, visibleCamera: $visibleCamera)
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) { mapControls.padding(10) }
            Divider()
            ZStack {
                FlightDetailSidebar(model: model)
                    .id(model.hex)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.2), value: model.hex)
            .frame(minWidth: 280, idealWidth: 310, maxWidth: 340)
            .background(.background)
        }
        .environment(\.displayOptions, model.display)
        .frame(minWidth: 620, minHeight: 420)
        // The camera follows the aircraft, never the route: a route or track loading doesn't move it.
        .onChange(of: model.hex, initial: true) { centreOnAircraft() }
        .onChange(of: model.flight != nil) { if centredHex != model.hex { centreOnAircraft() } }
    }

    /// Map framing controls, styled like MapKit's own zoom control.
    private var mapControls: some View {
        VStack(spacing: 0) {
            mapButton("Show Whole Flight", "point.topleft.down.to.point.bottomright.curvepath", action: frameFlight)
            Divider().frame(width: 20)
            mapButton("Center on Aircraft", "scope", action: frameAircraft)
                .disabled(model.flight == nil)
            if observerPoint() != nil {
                Divider().frame(width: 20)
                mapButton("Show Flights Near You (\(model.display.radius(model.radiusNM)))", "location.circle", action: frameNearby)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }

    private func mapButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }

    // MARK: Framing

    /// Opens on a local view around the aircraft (about the search area across). After that, a
    /// different aircraft keeps the current zoom and the map pans to it. Showing the whole flight
    /// is left to the "Show Whole Flight" button, so long-haul routes never zoom the map out.
    private func centreOnAircraft() {
        guard let f = model.flight else {
            // No position yet: show the user's area until it arrives.
            if centredHex == nil, let observer = observerPoint() {
                move(to: DetailCamera.localRegion(around: observer, radiusNM: model.radiusNM))
            }
            return
        }
        if centredHex != nil, let current = visibleCamera {
            setCamera(.camera(MapCamera(centerCoordinate: f.geoPoint.coordinate, distance: current.distance)))
        } else {
            move(to: DetailCamera.localRegion(around: f.geoPoint, radiusNM: model.radiusNM))
        }
        centredHex = model.hex
    }

    /// Fits origin, destination (including the arc between them), the recorded track and the
    /// aircraft, or the aircraft and the observer when the route is unknown.
    private func frameFlight() {
        var points: [GeoPoint] = []
        if let f = model.flight {
            points.append(f.geoPoint)
            points += model.plannedPath
            if let origin = model.departedFrom { points.append(origin.geoPoint) }
            if f.route == nil, let observer = observerPoint(),
               FlightService.gcDistance(observer.lat, observer.lon, f.lat, f.lon) < 300 {
                points.append(observer)
            }
            points += model.history.map(\.point)
        } else if let observer = observerPoint() {
            points.append(observer)
        }
        guard let fr = DetailFormat.framing(points) else { return }
        move(to: fr)
    }

    /// Centres on the aircraft, about 60 nm across.
    private func frameAircraft() {
        guard let f = model.flight else { return }
        let d = 1.0
        move(to: MKCoordinateRegion(center: f.geoPoint.coordinate,
                                    span: MKCoordinateSpan(latitudeDelta: d, longitudeDelta: d / max(0.2, cos(f.lat * .pi / 180)))))
    }

    /// Fits the search-radius circle around the user.
    private func frameNearby() {
        guard let observer = observerPoint() else { return }
        let d = Double(model.radiusNM) / 60 * 1.15
        move(to: MKCoordinateRegion(center: observer.coordinate,
                                    span: MKCoordinateSpan(latitudeDelta: d * 2, longitudeDelta: d * 2 / max(0.2, cos(observer.lat * .pi / 180)))))
    }

    private func move(to fr: DetailFormat.Framing) {
        move(to: MKCoordinateRegion(center: fr.center.coordinate,
                                    span: MKCoordinateSpan(latitudeDelta: fr.latitudeDelta, longitudeDelta: fr.longitudeDelta)))
    }

    private func move(to region: MKCoordinateRegion) { setCamera(.region(region)) }

    /// Glides to `position`, or jumps there with Reduce Motion on.
    private func setCamera(_ position: MapCameraPosition) {
        if reduceMotion {
            camera = position
        } else {
            withAnimation(.easeInOut(duration: 0.6)) { camera = position }
        }
    }
}

// MARK: - Map

private struct FlightDetailMap: View {
    @ObservedObject var model: FlightDetailModel
    @Binding var camera: MapCameraPosition
    @Binding var latitudeSpan: Double
    @Binding var visibleCamera: MapCamera?
    @Environment(\.openFlightDetail) private var openFlight
    private let observer = observerPoint()
    /// The visible region and map size, for label placement.
    @State private var region: MKCoordinateRegion?
    @State private var mapSize: CGSize = .zero
    /// Nearby aircraft whose labels fit without overlapping (see `MapLabelLayout`).
    @State private var labelled: Set<String> = []

    private var detail: DetailFormat.MapDetail { DetailFormat.MapDetail(latitudeSpan: latitudeSpan) }

    var body: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            if let observer {
                // A polygon, not MapCircle: MapCircle stopped the map rendering tiles while on screen.
                MapPolygon(coordinates: FlightMath.removingRepeats(FlightMath.circle(around: observer, radiusNM: Double(model.radiusNM)))
                    .map(\.coordinate))
                    .foregroundStyle(Color.blue.opacity(0.05))
                    .stroke(Color.blue.opacity(0.55), lineWidth: 1.5)
                if detail >= .icons {
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: observer.lat + Double(model.radiusNM) / 60,
                                                                      longitude: observer.lon), anchor: .center) {
                        Text(model.display.radius(model.radiusNM))
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.blue.opacity(0.8)))
                            .accessibilityLabel("Search radius \(model.display.radius(model.radiusNM))")
                    }
                    .annotationTitles(.hidden)
                }
            }
            // The route still to fly: bold accent dashes over a solid dark casing, so it reads on
            // any map style. Lighter when the destination is only an estimate.
            ForEach(Array(model.remainingLines.enumerated()), id: \.offset) { _, line in
                MapPolyline(coordinates: line.map(\.coordinate))
                    .stroke(Color.black.opacity(0.4), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: line.map(\.coordinate))
                    .stroke(Color.accentColor.opacity(model.destinationEstimated ? 0.65 : 1),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [6, 8]))
            }
            // Route unknown: a thin dotted vector along the current heading (about 10 minutes ahead).
            ForEach(Array(model.headingLines.enumerated()), id: \.offset) { _, line in
                MapPolyline(coordinates: line.map(\.coordinate))
                    .stroke(Color.accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.5, 5]))
            }
            // A dark casing under the flown track keeps it legible over any terrain.
            ForEach(Array(model.flownLines.enumerated()), id: \.offset) { _, line in
                MapPolyline(coordinates: line.map(\.coordinate))
                    .stroke(Color.black.opacity(0.25), style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: line.map(\.coordinate))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            if let r = model.flight?.route {
                airport(r.from, role: "Departure")
                airport(r.to, role: model.destinationEstimated ? "Estimated destination" : "Destination")
            } else if let origin = model.departedFrom {
                airport(origin, role: "Departure")
            }
            if detail >= .icons {
                ForEach(model.nearby) { other in
                    Annotation("", coordinate: other.geoPoint.coordinate, anchor: .center) {
                        Button { openFlight(other) } label: {
                            NearbyMarker(f: other, showLabel: labelled.contains(other.id))
                        }
                        .buttonStyle(.plain)
                        .help("Show \(other.displayNumber)")
                        .accessibilityLabel("\(other.displayNumber), \(model.display.altitude(other.altitude))")
                        .accessibilityHint("Shows this aircraft’s details")
                    }
                    .annotationTitles(.hidden)
                }
            }
            if let observer {
                Annotation("You", coordinate: observer.coordinate, anchor: .center) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(radius: 1)
                        .accessibilityLabel("Your location")
                }
                .annotationTitles(detail == .labelled ? .automatic : .hidden)
            }
            if let f = model.flight {
                Annotation("", coordinate: f.geoPoint.coordinate, anchor: .center) {
                    SelectedMarker(f: f, isLive: model.isLive)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapZoomStepper()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            region = context.region
            latitudeSpan = context.region.span.latitudeDelta
            visibleCamera = context.camera
            relabel()
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { mapSize = geo.size; relabel() }
                    .onChange(of: geo.size) { _, size in mapSize = size; relabel() }
            }
        }
        .onChange(of: labelKey) { relabel() }
    }

    /// Changes when the aircraft to label move or change.
    private var labelKey: [String] {
        model.nearby.map { "\($0.id)\(Int($0.lat * 100)),\(Int($0.lon * 100))" } + [model.hex]
    }

    /// Picks which nearby aircraft get labels: nearest first, never overlapping each other, the
    /// icons, or the shown aircraft's label; previous labels are kept where possible.
    private func relabel() {
        guard let r = region, mapSize.width > 0, mapSize.height > 0 else { return }
        let viewport = MapLabelLayout.Viewport(center: GeoPoint(lat: r.center.latitude, lon: r.center.longitude),
                                               latitudeDelta: r.span.latitudeDelta, longitudeDelta: r.span.longitudeDelta,
                                               size: mapSize)
        var items = model.nearby.sorted { $0.distance < $1.distance }
            .map { MapLabelLayout.Item(id: $0.id, point: $0.geoPoint, text: $0.displayNumber) }
        if let f = model.flight {
            items.insert(MapLabelLayout.Item(id: f.id, point: f.geoPoint, text: f.displayNumber), at: 0)
        }
        var next = MapLabelLayout.labelled(items, in: viewport, pinned: model.flight?.id, prefer: labelled)
        if let id = model.flight?.id { next.remove(id) }
        if next != labelled { labelled = next }
    }

    private func airport(_ a: Airport, role: String) -> some MapContent {
        Annotation("", coordinate: a.geoPoint.coordinate, anchor: .center) {
            VStack(spacing: 2) {
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.primary, lineWidth: 2.5))
                Text(a.code)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary)
                    .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 1.5)
                    .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 1.5)
            }
            // Keep the dot (not the label) on the coordinate.
            .offset(y: 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(role) airport, \(a.code), \(a.city)")
        }
        .annotationTitles(.hidden)
    }
}

/// Another aircraft near the user: a small class symbol with a halo, plus its label when
/// `MapLabelLayout` found room. The label is an overlay so the icon stays on the coordinate.
private struct NearbyMarker: View {
    let f: Flight
    let showLabel: Bool

    var body: some View {
        let kind = AircraftClass(typeCode: f.typeCode)
        Image(systemName: kind.symbol)
            .font(.system(size: 12 * kind.iconScale, weight: .semibold))
            .foregroundStyle(f.looksLikeAirline ? Color.primary.opacity(0.75) : Color.secondary)
            .rotationEffect(.degrees(kind == .rotorcraft ? 0 : (f.track ?? 90) - 90))
            .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 1.2)
            .frame(width: MapLabelLayout.iconSize.width, height: MapLabelLayout.iconSize.height)
            .overlay(alignment: .top) {
                if showLabel {
                    Text(f.displayNumber)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 1)
                        .fixedSize()
                        .offset(y: MapLabelLayout.iconSize.height / 2 + MapLabelLayout.labelOffset)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: showLabel)
            .contentShape(Rectangle())
    }
}

/// The aircraft being shown: larger, accent-coloured, with a label capsule (grey once the signal is lost).
private struct SelectedMarker: View {
    let f: Flight
    let isLive: Bool

    var body: some View {
        let kind = AircraftClass(typeCode: f.typeCode)
        let tint = isLive ? Color.accentColor : Color.gray
        VStack(spacing: 2) {
            Image(systemName: kind.symbol)
                .font(.system(size: 24 * kind.iconScale, weight: .semibold))
                .foregroundStyle(tint)
                // The symbol points east; the map is always north-up.
                .rotationEffect(.degrees(kind == .rotorcraft ? 0 : (f.track ?? 90) - 90))
                .shadow(color: .white.opacity(0.9), radius: 0.8)
                .shadow(color: .black.opacity(0.35), radius: 2)
            Text(f.displayNumber)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(tint))
                .fixedSize()
        }
        // Keep the symbol (not the label) centred on the position.
        .offset(y: 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(f.displayNumber), \(isLive ? "current position" : "last known position")")
    }
}

// MARK: - Sidebar

private struct FlightDetailSidebar: View {
    @ObservedObject var model: FlightDetailModel
    private var o: DisplayOptions { model.display }

    var body: some View {
        if let f = model.flight {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(f)
                    photoSection
                    if let r = f.route {
                        routeCard(f, from: r.from, to: r.to)
                    } else if let origin = model.departedFrom {
                        routeCard(f, from: origin, to: nil)
                    } else if f.looksLikeAirline {
                        DetailCard("Route") {
                            Label("Route not available for \(f.callsign)", systemImage: "questionmark.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        }
                    }
                    liveDataSection(f)
                    if Shared.location != nil { fromYouCard(f) }
                    aircraftCard(f)
                    linksCard(f)
                }
                .padding(16)
            }
        } else {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking up \(model.hex.uppercased())…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Header

    private func header(_ f: Flight) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Badge(f: f, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(DetailFormat.title(for: f, hex: model.hex))
                        .font(.title.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .textSelection(.enabled)
                    if !identityLine(f).isEmpty {
                        Text(identityLine(f))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                StatusPill(model: model)
                if let alert = DetailFormat.squawkAlert(model.squawk) {
                    Pill(text: "\(alert) · \(model.squawk ?? "")", symbol: "exclamationmark.triangle.fill", tint: .red)
                }
            }
        }
    }

    /// "Southwest Airlines · SWA2383": who flies it, plus the callsign when it differs from the number.
    private func identityLine(_ f: Flight) -> String {
        var parts: [String] = []
        if !f.airlineName.isEmpty {
            parts.append(f.airlineName)
        } else if let m = f.aircraft?.model {
            parts.append(m)
        } else if !f.looksLikeAirline {
            parts.append("Private / general aviation")
        }
        if !f.callsign.isEmpty, f.callsign != DetailFormat.title(for: f, hex: model.hex) { parts.append(f.callsign) }
        return parts.joined(separator: " · ")
    }

    // MARK: Photo

    /// The airframe photo with its required credit; both open the photo's page.
    /// Hidden entirely when there's no photo.
    @ViewBuilder private var photoSection: some View {
        Group {
            switch model.photo {
            case .loading(let ratio):
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .aspectRatio(ratio, contentMode: .fit)
                    .overlay {
                        Image(systemName: "airplane")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.quaternary)
                    }
                    .accessibilityLabel("Loading aircraft photo")
            case .loaded(let photo, let image):
                VStack(alignment: .leading, spacing: 5) {
                    Link(destination: photo.pageURL) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(photo.aspectRatio, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Open this photo on Planespotters.net")
                    .accessibilityLabel("Photo of \(model.flight?.reg ?? model.hex.uppercased()), \(photo.credit)")
                    Link(photo.credit, destination: photo.pageURL)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .transition(.opacity)
            case .unavailable:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: photoPhase)
    }

    private var photoPhase: Int {
        switch model.photo {
        case .loading: 0
        case .loaded: 1
        case .unavailable: 2
        }
    }

    // MARK: Route

    private func routeCard(_ f: Flight, from: Airport, to: Airport?) -> some View {
        DetailCard("Route", footer: model.routeNote) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    endpoint(from.code, from.city, role: "From", alignment: .leading)
                    Spacer(minLength: 8)
                    if let to {
                        endpoint(to.code, model.destinationEstimated ? "\(to.city) (est.)" : to.city,
                                 role: model.destinationEstimated ? "To, estimated" : "To", alignment: .trailing)
                    } else {
                        endpoint("—", "Unknown", role: "Destination", alignment: .trailing)
                    }
                }
                RouteLine(iconSize: 13, progress: to == nil ? nil : f.progress)
                    .frame(height: 18)
                if to != nil, let flown = model.flownNM, let left = model.remainingNM {
                    HStack {
                        Text("\(DetailFormat.distance(flown, units: o.units)) flown")
                        Spacer()
                        Text("\(DetailFormat.distance(left, units: o.units)) to go")
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
                timing
            }
        }
    }

    @ViewBuilder private var timing: some View {
        let departed = model.departureTime
        let arrival = model.arrival
        if departed != nil || arrival != nil {
            Divider()
            VStack(spacing: 0) {
                if let departed {
                    TimingRow(label: "Departed", time: departed.formatted(date: .omitted, time: .shortened),
                              detail: DetailFormat.ago(departed))
                }
                switch arrival {
                case .landed?:
                    TimingRow(label: "Arrival", time: "Landed", detail: nil)
                case .landing?:
                    TimingRow(label: "Arrival", time: "Landing now", detail: nil)
                case .estimate(let t)?:
                    TimingRow(label: "Arrival (est.)",
                              time: "≈ " + Date().addingTimeInterval(t).formatted(date: .omitted, time: .shortened),
                              detail: "in \(FlightMath.durationText(t)) at current speed")
                case nil:
                    EmptyView()
                }
            }
        }
    }

    private func endpoint(_ code: String, _ city: String, role: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(code).font(.system(size: 28, weight: .bold)).textSelection(.enabled)
            Text(city).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(role): \(code), \(city)")
    }

    // MARK: Live data

    private func liveDataSection(_ f: Flight) -> some View {
        let stale = !model.isLive
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Live Data",
                          trailing: stale ? model.lastSeen.map { "Last reported \($0.formatted(date: .omitted, time: .shortened))" } : nil)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                if model.onGround {
                    Tile(label: "Altitude", value: "On ground")
                } else {
                    Tile(label: "Altitude", value: o.altitude(f.altitude),
                         symbol: abs(f.verticalRate) > 300 ? (f.verticalRate > 0 ? "arrow.up.right" : "arrow.down.right") : nil,
                         spoken: abs(f.verticalRate) > 300 ? (f.verticalRate > 0 ? "climbing" : "descending") : nil)
                    Tile(label: "Vertical Speed", value: DetailFormat.verticalRate(f.verticalRate, units: o.units))
                }
                Tile(label: "Ground Speed", value: o.speed(f.speed))
                if let track = f.track { Tile(label: "Track", value: DetailFormat.heading(track)) }
                if let squawk = model.squawk {
                    Tile(label: "Squawk", value: squawk, tint: DetailFormat.squawkAlert(squawk) == nil ? nil : .red)
                }
            }
            .opacity(stale ? 0.6 : 1)
        }
    }

    // MARK: From you

    private func fromYouCard(_ f: Flight) -> some View {
        DetailCard("From You") {
            VStack(spacing: 0) {
                if let sky = model.skyPosition {
                    let text = DetailFormat.lookUp(sky)
                    HStack(spacing: 12) {
                        SkyDome(position: sky)
                            .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(text.headline).font(.callout.weight(.semibold))
                            Text(text.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Where to look: \(text.headline). \(text.detail)")
                    Divider()
                    InfoRow(label: "Line of sight", value: DetailFormat.distance(sky.slantRangeNM, units: o.units))
                    Divider()
                }
                InfoRow(label: "Ground distance", value: DetailFormat.distance(f.distance, units: o.units))
                if model.skyPosition == nil {
                    Divider()
                    InfoRow(label: "Direction", value: DetailFormat.heading(f.bearing))
                }
            }
        }
    }

    // MARK: Aircraft

    private func aircraftCard(_ f: Flight) -> some View {
        var rows: [(String, String)] = []
        if let m = f.aircraft?.model { rows.append(("Model", m)) }
        if !f.typeCode.isEmpty { rows.append(("Type", f.typeCode)) }
        rows.append(("Registration", f.reg))
        rows.append(("ICAO hex", f.id.uppercased()))
        if let owner = f.aircraft?.owner, owner != f.airlineName { rows.append(("Operator", owner)) }
        if let year = model.buildYear { rows.append(("Built", DetailFormat.built(year))) }
        return DetailCard("Aircraft") {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Divider() }
                    InfoRow(label: row.0, value: row.1)
                }
            }
        }
    }

    // MARK: Links

    private func linksCard(_ f: Flight) -> some View {
        DetailCard(nil) {
            VStack(spacing: 0) {
                if let url = model.adsbLolURL {
                    LinkRow(title: "View on adsb.lol", symbol: "dot.radiowaves.left.and.right", url: url)
                }
                if let url = model.planespottersURL {
                    Divider()
                    LinkRow(title: "Planespotters.net", symbol: "camera", url: url)
                }
                if let url = model.adsbLolURL {
                    Divider()
                    ShareLink(item: url, subject: Text(DetailFormat.title(for: f, hex: model.hex)),
                              message: Text(shareMessage(f))) {
                        LinkRowLabel(title: "Share Flight", symbol: "square.and.arrow.up", trailing: nil)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func shareMessage(_ f: Flight) -> String {
        let sub = DetailFormat.subtitle(for: f)
        let title = DetailFormat.title(for: f, hex: model.hex)
        return sub.isEmpty ? title : "\(title) · \(sub)"
    }
}

// MARK: - Sidebar components

/// Live / On Ground / Last seen status capsule.
private struct StatusPill: View {
    @ObservedObject var model: FlightDetailModel

    var body: some View {
        if model.isLive {
            if model.arrival == .landed {
                Pill(text: "Landed", symbol: "airplane.arrival", tint: .secondary)
            } else if model.onGround {
                Pill(text: "On Ground", symbol: "road.lanes", tint: .secondary)
            } else {
                LivePill()
            }
        } else if let seen = model.lastSeen {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Pill(text: "Signal lost · \(DetailFormat.ago(seen, now: ctx.date))", symbol: "antenna.radiowaves.left.and.right.slash",
                     tint: .orange)
                    .help("Last position received at \(seen.formatted(date: .omitted, time: .standard))")
            }
        } else {
            Pill(text: "Not currently reported", symbol: "antenna.radiowaves.left.and.right.slash", tint: .secondary)
        }
    }
}

private struct LivePill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            Text("Live")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.green)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.green.opacity(0.15)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live")
    }
}

private struct Pill: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.15)))
    }
}

/// The airline logo, or the aircraft's class symbol in a rounded tile when there's no logo.
private struct Badge: View {
    let f: Flight
    let size: CGFloat
    @Environment(\.displayOptions) private var o

    var body: some View {
        Group {
            if o.showLogos, AirlineLogos.file(for: f.logoKey?.id) != nil {
                AirlineLogo(code: f.logoKey?.id, size: size)
            } else {
                let kind = AircraftClass(typeCode: f.typeCode)
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .overlay {
                        Image(systemName: kind.symbol)
                            .font(.system(size: size * 0.45 * kind.iconScale, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(kind == .rotorcraft ? 0 : -45))
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let trailing {
                Text(trailing).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 2)
    }
}

/// A titled, rounded group of content, like a grouped form section.
private struct DetailCard<Content: View>: View {
    let title: String?
    let footer: String?
    let content: Content

    init(_ title: String?, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { SectionHeader(title: title) }
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
            if let footer {
                Label(footer, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .font(.callout)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct TimingRow: View {
    let label: String
    let time: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(time).fontWeight(.semibold)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            .monospacedDigit()
        }
        .font(.callout)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

/// A big-number fact tile (altitude, speed, …).
private struct Tile: View {
    let label: String
    let value: String
    var symbol: String? = nil
    var spoken: String? = nil
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let symbol {
                    Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)\(spoken.map { ", \($0)" } ?? "")")
    }
}

private struct LinkRow: View {
    let title: String
    let symbol: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            LinkRowLabel(title: title, symbol: symbol, trailing: "arrow.up.forward")
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }
}

private struct LinkRowLabel: View {
    let title: String
    let symbol: String
    let trailing: String?

    var body: some View {
        HStack {
            Label(title, systemImage: symbol).foregroundStyle(Color.accentColor)
            Spacer()
            if let trailing { Image(systemName: trailing).font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .font(.callout)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// A small sky chart: the outer circle is the horizon, the centre is straight up. Drawn like a
/// map (north up, east right) so it reads the same way as the map beside it. The dot marks the
/// aircraft; a hollow dot means it's below the horizon in that direction.
private struct SkyDome: View {
    let position: SkyPosition

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let r = size / 2 - 1
            let centre = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            // Distance from the centre: 0 at the zenith, r at the horizon (clamped for below it).
            let d = r * (1 - max(0, min(90, position.elevation)) / 90)
            let az = position.azimuth * .pi / 180
            let dot = CGPoint(x: centre.x + d * sin(az), y: centre.y - d * cos(az))
            ZStack {
                Circle().fill(Color.blue.opacity(0.08))
                Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1)
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5).padding(r / 3)       // 30° up
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5).padding(r * 2 / 3)   // 60° up
                ForEach(0..<4, id: \.self) { i in
                    let label = ["N", "E", "S", "W"][i]
                    let a = Double(i) * .pi / 2
                    Text(label)
                        .font(.system(size: 7, weight: label == "N" ? .bold : .medium))
                        .foregroundStyle(label == "N" ? Color.primary : Color.secondary)
                        .position(x: centre.x + (r - 6) * sin(a), y: centre.y - (r - 6) * cos(a))
                }
                Path { p in p.move(to: centre); p.addLine(to: dot) }
                    .stroke(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                Circle()
                    .fill(position.isAboveHorizon ? Color.accentColor : Color.clear)
                    .overlay(Circle().stroke(position.isAboveHorizon ? Color.white : Color.secondary, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .position(dot)
            }
            .frame(width: size, height: size)
            .position(centre)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Opening other flights

private struct OpenFlightDetailKey: EnvironmentKey {
    static let defaultValue: @MainActor (Flight) -> Void = { FlightDetail.show(hex: $0.id, snapshot: $0) }
}

extension EnvironmentValues {
    /// Opens another aircraft's details (clicking a nearby flight on the map). Hosts override
    /// this to switch in place.
    var openFlightDetail: @MainActor (Flight) -> Void {
        get { self[OpenFlightDetailKey.self] }
        set { self[OpenFlightDetailKey.self] = newValue }
    }
}
