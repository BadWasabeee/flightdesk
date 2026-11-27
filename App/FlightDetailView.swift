import SwiftUI
import MapKit

// MARK: - Model

/// Live state for one aircraft's detail window. Polls adsb.lol while running and keeps the
/// last known data when the aircraft stops being reported.
@MainActor
final class FlightDetailModel: ObservableObject {
    let hex: String
    /// Unit formatters from the user's settings, in the system (non-LED) style.
    let display: DisplayOptions

    @Published private(set) var flight: Flight?
    @Published private(set) var squawk: String?
    @Published private(set) var onGround = false
    /// True while the latest poll returned a fresh position.
    @Published private(set) var isLive = false
    /// When the most recent position was received, once a poll has returned one.
    @Published private(set) var lastSeen: Date?
    /// Positions observed while the window has been open, oldest first.
    @Published private(set) var trail: [TimedPoint] = []
    /// The flight's recorded track from OpenSky, when available.
    @Published private(set) var history: [TimedPoint] = []
    /// Departure airport read from the start of the recorded track.
    @Published private(set) var departedFrom: Airport?
    /// How the shown route was worked out, when it isn't the verified scheduled route.
    @Published private(set) var routeNote: String?
    /// Other aircraft within the user's search radius.
    @Published private(set) var nearby: [Flight] = []
    /// The user's search radius, drawn around their location.
    let radiusNM: Int
    private let includeGA: Bool

    private static let pollInterval: Duration = .seconds(5)
    private static let nearbyInterval: Duration = .seconds(15)
    /// OpenSky's anonymous quota is small, so the recorded track is refreshed sparingly.
    private static let historyInterval: Duration = .seconds(180)
    /// A position older than this counts as no longer live.
    private static let staleAfter: TimeInterval = 60

    /// Route from the lookup cache, re-verified against every live position.
    private var candidateRoute: RouteInfo?
    private var aircraftInfo: AircraftInfo?
    private var enrichedCallsign: String?
    private var poller: Task<Void, Never>?
    private var nearbyPoller: Task<Void, Never>?
    private var historyPoller: Task<Void, Never>?

    /// `nearby` seeds the map's other aircraft (when switching planes) until the next refresh.
    init(hex: String, snapshot: Flight?, nearby: [Flight] = []) {
        self.hex = hex
        self.nearby = nearby.filter { $0.id != hex }
        let settings = AppSettings.load()
        var display = settings.display
        display.style = .standard
        self.display = display
        radiusNM = settings.radius.nm
        includeGA = settings.includeGA
        flight = snapshot
        candidateRoute = snapshot?.route
        aircraftInfo = snapshot?.aircraft
        isLive = snapshot != nil
        // The snapshot can be minutes old, so it only stands in until the first live position.
        if let snapshot { trail = [TimedPoint(point: snapshot.geoPoint, time: .distantPast)] }
    }

    deinit {
        poller?.cancel()
        nearbyPoller?.cancel()
        historyPoller?.cancel()
    }

    func start() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
        nearbyPoller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollNearby()
                try? await Task.sleep(for: Self.nearbyInterval)
            }
        }
        historyPoller = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))   // let the first live position arrive
            while !Task.isCancelled {
                await self?.pollHistory()
                try? await Task.sleep(for: Self.historyInterval)
            }
        }
    }

    func stop() {
        [poller, nearbyPoller, historyPoller].forEach { $0?.cancel() }
        poller = nil; nearbyPoller = nil; historyPoller = nil
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
            routeNote = "Departure confirmed by the flight’s track"
        } else if let dest = AirportDB.likelyDestination(for: f), dest.code != origin.code {
            f.route = RouteInfo(airline: scheduled?.airline, flightNo: scheduled?.flightNo,
                                airlineCode: scheduled?.airlineCode, from: origin, to: dest)
            routeNote = "Departure from the flight’s track · destination estimated from its descent"
        } else {
            f.route = nil
            routeNote = "Departure from the flight’s track"
        }
    }

    private func poll() async {
        let report: AircraftReport?
        do {
            report = try await FlightDetailService.report(hex: hex)
        } catch {
            fdLog.info("Detail poll for \(self.hex, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
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
            // Keep the snapshot's route if a lookup fails for the same callsign.
            if lookup.route != nil || previous != f.callsign { candidateRoute = lookup.route }
            aircraftInfo = lookup.aircraft ?? aircraftInfo
            guard !Task.isCancelled else { return }
        }
        f.aircraft = AircraftInfo(model: aircraftInfo?.model ?? f.aircraft?.model,
                                  owner: aircraftInfo?.owner ?? f.aircraft?.owner)
        resolveRoute(&f)

        trail.removeAll { $0.time == .distantPast }
        let moved = trail.last.map { FlightService.gcDistance($0.point.lat, $0.point.lon, f.lat, f.lon) >= 0.05 } ?? true
        if moved { trail.append(TimedPoint(point: f.geoPoint, time: report.positionTime)) }
        flight = f
        squawk = report.squawk
        onGround = report.onGround
        lastSeen = report.positionTime
        isLive = -report.positionTime.timeIntervalSinceNow < Self.staleAfter
    }

    // MARK: Derived values

    /// Window title, e.g. "DL1342 · SEA → JFK".
    static func title(for f: Flight?, hex: String) -> String {
        guard let f else { return hex.uppercased() }
        let number = f.displayNumber.isEmpty ? hex.uppercased() : f.displayNumber
        guard let r = f.route else { return number }
        return "\(number) · \(r.from.code) → \(r.to.code)"
    }

    var flownNM: Double? {
        guard let f = flight, let r = f.route else { return nil }
        return FlightService.gcDistance(r.from.lat, r.from.lon, f.lat, f.lon)
    }

    var remainingNM: Double? {
        guard let f = flight, let r = f.route else { return nil }
        return FlightService.gcDistance(f.lat, f.lon, r.to.lat, r.to.lon)
    }

    /// Time to destination at the current ground speed, while airborne and live.
    var timeToGo: TimeInterval? {
        guard isLive, !onGround, let f = flight, let left = remainingNM else { return nil }
        return FlightMath.timeToGo(remainingNM: left, speedKT: f.speed)
    }

    /// Planned great-circle route, origin to destination.
    var plannedPath: [GeoPoint] {
        guard let r = flight?.route else { return [] }
        return FlightMath.removingRepeats(FlightMath.greatCircle(from: r.from.geoPoint, to: r.to.geoPoint))
    }

    /// Flown track: the recorded track plus live positions since, or (without a recorded track)
    /// a great circle from the origin to the first observed position, then the observed trail.
    var flownPath: [GeoPoint] {
        // Merge by time so the line always runs through the aircraft's current position.
        let end = history.last?.time ?? .distantPast
        var points = history.map(\.point) + trail.filter { $0.time > end }.map(\.point)
        if let f = flight, points.last != f.geoPoint { points.append(f.geoPoint) }
        if history.isEmpty, let r = flight?.route, let first = points.first {
            points = FlightMath.greatCircle(from: r.from.geoPoint, to: first).dropLast() + points
        }
        return FlightMath.removingRepeats(points)
    }

    var adsbLolURL: URL? { URL(string: "https://adsb.lol/?icao=\(hex)") }
}

private extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

// MARK: - Window content

struct FlightDetailView: View {
    @ObservedObject var model: FlightDetailModel

    var body: some View {
        HStack(spacing: 0) {
            FlightDetailMap(model: model)
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            FlightDetailSidebar(model: model)
                .frame(width: 280)
        }
        .frame(minWidth: 620, minHeight: 420)
    }
}

// MARK: - Map

private struct FlightDetailMap: View {
    @ObservedObject var model: FlightDetailModel
    @State private var camera: MapCameraPosition = .automatic
    @Environment(\.openFlightDetail) private var openFlight
    private let observer = Shared.location.map { GeoPoint(lat: $0.lat, lon: $0.lon) }

    /// Changes when the set of things worth framing changes (first data, route found).
    private var framingKey: String {
        let r = model.flight?.route
        return "\(model.flight != nil)|\(r?.from.code ?? "")|\(r?.to.code ?? "")|\(model.history.isEmpty)"
    }

    var body: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            if let r = model.flight?.route {
                MapPolyline(coordinates: model.plannedPath.map(\.coordinate))
                    .stroke(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 6]))
                airport(r.from)
                airport(r.to)
            }
            if model.flight?.route == nil, let origin = model.departedFrom {
                airport(origin)
            }
            if model.flownPath.count > 1 {
                MapPolyline(coordinates: model.flownPath.map(\.coordinate))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            if let observer {
                // Drawn as a polygon: MapCircle stopped the map rendering tiles while on screen.
                MapPolygon(coordinates: FlightMath.circle(around: observer, radiusNM: Double(model.radiusNM)).map(\.coordinate))
                    .foregroundStyle(Color.blue.opacity(0.06))
                    .stroke(Color.blue.opacity(0.6), lineWidth: 1.5)
                // Radius label on the circle's northern edge.
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: observer.lat + Double(model.radiusNM) / 60,
                                                                  longitude: observer.lon), anchor: .center) {
                    Text(model.display.radius(model.radiusNM))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.blue.opacity(0.8)))
                }
            }
            ForEach(model.nearby) { other in
                Annotation("", coordinate: other.geoPoint.coordinate, anchor: .center) {
                    Button { openFlight(other) } label: {
                        VStack(spacing: 1) {
                            let kind = AircraftClass(typeCode: other.typeCode)
                            Image(systemName: kind.symbol)
                                .font(.system(size: 14 * kind.iconScale, weight: .semibold))
                                .rotationEffect(.degrees((other.track ?? 90) - 90))
                            Text(other.displayNumber)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 1)
                    }
                    .buttonStyle(.plain)
                    .help("Show \(other.displayNumber)")
                }
            }
            if let observer {
                Annotation("You", coordinate: observer.coordinate, anchor: .center) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(radius: 1)
                }
            }
            if let f = model.flight {
                Annotation(f.displayNumber, coordinate: f.geoPoint.coordinate, anchor: .center) {
                    let kind = AircraftClass(typeCode: f.typeCode)
                    Image(systemName: kind.symbol)
                        .font(.system(size: 22 * kind.iconScale, weight: .semibold))
                        .foregroundStyle(model.isLive ? Color.accentColor : Color.secondary)
                        .shadow(color: .black.opacity(0.35), radius: 1.5)
                        // The symbol points east; the map is always north-up.
                        .rotationEffect(.degrees((f.track ?? 90) - 90))
                        .accessibilityLabel("Aircraft position")
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapZoomStepper()
            MapScaleView()
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Button(action: frameFlight) { Image(systemName: "scope") }
                    .help("Show the whole flight")
                if observer != nil {
                    Button(action: frameNearby) { Image(systemName: "circle.dashed") }
                        .help("Show flights near you (\(model.display.radius(model.radiusNM)))")
                }
            }
            .padding(10)
        }
        .onChange(of: framingKey, initial: true) {
            if !camera.positionedByUser { frameFlight() }
        }
    }

    private func airport(_ a: Airport) -> some MapContent {
        Annotation(a.code, coordinate: a.geoPoint.coordinate, anchor: .center) {
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color.primary, lineWidth: 2))
        }
    }

    /// Fits the search-radius circle around the user.
    private func frameNearby() {
        guard let observer else { return }
        let d = Double(model.radiusNM) / 60 * 1.15
        let span = MKCoordinateSpan(latitudeDelta: d * 2, longitudeDelta: d * 2 / max(0.2, cos(observer.lat * .pi / 180)))
        withAnimation { camera = .region(MKCoordinateRegion(center: observer.coordinate, span: span)) }
    }

    /// Fits origin, destination (including the arc between them) and the aircraft, or the aircraft
    /// and the observer when the route is unknown.
    private func frameFlight() {
        var points: [GeoPoint] = []
        if let f = model.flight {
            points.append(f.geoPoint)
            if f.route != nil {
                points += model.plannedPath
            } else if let observer, FlightService.gcDistance(observer.lat, observer.lon, f.lat, f.lon) < 300 {
                points.append(observer)
            }
            points += model.history.map(\.point)
        } else if let observer {
            points.append(observer)
        }
        guard !points.isEmpty else { return }

        var rect = MKMapRect.null
        for p in points {
            rect = rect.union(MKMapRect(origin: MKMapPoint(p.coordinate), size: MKMapSize(width: 0, height: 0)))
        }
        // At least ~30 km across, plus a margin so markers aren't on the edge.
        let minSide = MKMapPointsPerMeterAtLatitude(points[0].lat) * 30_000
        let dx = max(rect.width * 0.15, (minSide - rect.width) / 2, 0)
        let dy = max(rect.height * 0.2, (minSide - rect.height) / 2, 0)
        withAnimation { camera = .rect(rect.insetBy(dx: -dx, dy: -dy)) }
    }
}

// MARK: - Sidebar

private struct FlightDetailSidebar: View {
    @ObservedObject var model: FlightDetailModel
    private var o: DisplayOptions { model.display }

    var body: some View {
        if let f = model.flight {
            VStack(alignment: .leading, spacing: 0) {
                header(f)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                Form {
                    if let r = f.route {
                        routeSection(f, from: r.from, to: r.to)
                    } else if let origin = model.departedFrom {
                        routeSection(f, from: origin, to: nil)
                    }
                    flightSection(f)
                    aircraftSection(f)
                    if Shared.location != nil {
                        Section("From you") {
                            LabeledContent("Distance", value: o.distance(f.distance))
                            LabeledContent("Direction", value: "\(Int(f.bearing.rounded()) % 360)° \(FlightMath.compassPoint(f.bearing))")
                        }
                    }
                    if let url = model.adsbLolURL {
                        Section {
                            Link(destination: url) {
                                Label("View on adsb.lol", systemImage: "safari")
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        } else {
            VStack(spacing: 8) {
                ProgressView()
                Text("Looking up \(model.hex.uppercased())…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ f: Flight) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AirlineLogo(code: f.logoKey?.id, size: 28)
                    .environment(\.displayOptions, o)
                Text(f.airlineName.isEmpty ? (f.aircraft?.model ?? "") : f.airlineName)
                    .font(.headline)
                    .lineLimit(2)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(f.displayNumber.isEmpty ? model.hex.uppercased() : f.displayNumber)
                    .font(.title.weight(.semibold))
                if !f.callsign.isEmpty, f.callsign != f.displayNumber {
                    Text(f.callsign).foregroundStyle(.secondary)
                }
            }
            status
        }
    }

    @ViewBuilder private var status: some View {
        if model.isLive {
            Label("Live", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(.green)
        } else if let seen = model.lastSeen {
            Text("Last seen \(seen.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Not currently reported").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func routeSection(_ f: Flight, from: Airport, to: Airport?) -> some View {
        Section {
            HStack(alignment: .top) {
                airport(from, alignment: .leading)
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 6)
                Spacer()
                if let to {
                    airport(to, alignment: .trailing)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("—").font(.system(size: 26, weight: .semibold, design: .rounded))
                        Text("Unknown").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let p = f.progress, let flown = model.flownNM, let left = model.remainingNM {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: p)
                    Text("\(o.distance(flown)) flown · \(o.distance(left)) to go")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let t = model.timeToGo {
                LabeledContent("Est. arrival") {
                    VStack(alignment: .trailing) {
                        Text(Date().addingTimeInterval(t).formatted(date: .omitted, time: .shortened))
                        Text("in \(FlightMath.durationText(t))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Route")
        } footer: {
            if let note = model.routeNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func airport(_ a: Airport, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(a.code).font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(a.city).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func flightSection(_ f: Flight) -> some View {
        Section("Flight") {
            LabeledContent("Altitude") {
                HStack(spacing: 4) {
                    if !model.onGround, abs(f.verticalRate) > 300 {
                        Image(systemName: f.verticalRate > 0 ? "arrow.up.right" : "arrow.down.right")
                            .foregroundStyle(.secondary)
                    }
                    Text(model.onGround ? "On ground" : o.altitude(f.altitude))
                }
            }
            if !model.onGround {
                LabeledContent("Vertical rate",
                               value: abs(f.verticalRate) < 100 ? "Level"
                                   : "\(Int(f.verticalRate).formatted(.number.sign(strategy: .always()))) fpm")
            }
            LabeledContent("Ground speed", value: o.speed(f.speed))
            if let track = f.track {
                LabeledContent("Track", value: String(format: "%03d° ", Int(track.rounded()) % 360) + FlightMath.compassPoint(track))
            }
            if let squawk = model.squawk {
                LabeledContent("Squawk", value: squawk)
            }
        }
    }

    private func aircraftSection(_ f: Flight) -> some View {
        Section("Aircraft") {
            if let modelName = f.aircraft?.model { LabeledContent("Model", value: modelName) }
            if !f.typeCode.isEmpty { LabeledContent("Type", value: f.typeCode) }
            LabeledContent("Registration", value: f.reg)
            LabeledContent("ICAO hex", value: f.id.uppercased())
            if let owner = f.aircraft?.owner, owner != f.airlineName { LabeledContent("Operator", value: owner) }
        }
    }
}

// MARK: - Opening other flights

private struct OpenFlightDetailKey: EnvironmentKey {
    static let defaultValue: @MainActor (Flight) -> Void = { FlightDetail.show(hex: $0.id, snapshot: $0) }
}

extension EnvironmentValues {
    /// Opens another aircraft's detail window (clicking a nearby flight on the map).
    var openFlightDetail: @MainActor (Flight) -> Void {
        get { self[OpenFlightDetailKey.self] }
        set { self[OpenFlightDetailKey.self] = newValue }
    }
}
