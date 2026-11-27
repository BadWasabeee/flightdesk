import SwiftUI
import MapKit

/// Main window content: searchable flight list, live map of the search radius and an inspector
/// for the selected aircraft.
struct MainWindowView: View {
    @ObservedObject var store: LiveStore
    @ObservedObject var radar: RadarModel

    /// The user's board settings in the Standard look, which follows the system appearance.
    private var display: DisplayOptions {
        var o = store.settings.display
        o.style = .standard
        return o
    }

    private var inspectorShown: Binding<Bool> {
        Binding(get: { radar.selection != nil }, set: { if !$0 { radar.selection = nil } })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $radar.sidebar) {
            FlightList(radar: radar, flights: FlightListFilter.apply(radar.flights, query: radar.query, sort: radar.sort))
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            RadarMap(radar: radar, radiusNM: store.settings.radius.nm)
                .inspector(isPresented: inspectorShown) {
                    FlightInspector(radar: radar)
                        .inspectorColumnWidth(min: 250, ideal: 280, max: 360)
                }
        }
        .searchable(text: $radar.query, placement: .sidebar, prompt: "Callsign, reg, type, airline")
        .navigationTitle("FlightDesk")
        .navigationSubtitle(store.placeName.isEmpty ? "No location set" : store.placeName)
        .toolbar { toolbar }
        .environment(\.displayOptions, display)
        .frame(minWidth: 900, minHeight: 600)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .status) {
            Text(statusText)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Radius", selection: $store.settings.radius) {
                ForEach(SearchRadius.allCases, id: \.self) { Text(display.radius($0.nm)).tag($0) }
            }
            .pickerStyle(.menu)
            .help("Search radius")
            Toggle(isOn: $store.settings.includeGA) {
                Label("Private & GA", systemImage: "airplane.circle")
            }
            .help(store.settings.includeGA ? "Hide private and general-aviation traffic" : "Show private and general-aviation traffic")
            Button { Task { await radar.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh now")
            .disabled(radar.isRefreshing)
        }
    }

    private var statusText: String {
        if !radar.status.isEmpty, radar.flights.isEmpty { return radar.status }
        let n = radar.flights.count
        var text = "\(n) aircraft within \(display.radius(store.settings.radius.nm))"
        if let t = radar.updated { text += " · \(t.formatted(date: .omitted, time: .standard))" }
        return text
    }
}

// MARK: - Sidebar

private struct FlightList: View {
    @ObservedObject var radar: RadarModel
    let flights: [Flight]

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $radar.selection) {
                Section {
                    ForEach(flights) { FlightRow(f: $0).tag($0.id) }
                } header: {
                    HStack {
                        Text("\(flights.count) aircraft")
                        Spacer()
                        Picker("Sort by", selection: $radar.sort) {
                            ForEach(FlightSort.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
            }
            .contextMenu(forSelectionType: Flight.ID.self) { ids in
                Button("Open Details") { openDetails(ids) }.disabled(ids.isEmpty)
            } primaryAction: { openDetails($0) }
            .onChange(of: radar.selection) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
            .overlay { emptyState }
        }
    }

    private func openDetails(_ ids: Set<Flight.ID>) {
        for f in radar.flights where ids.contains(f.id) { FlightDetail.show(hex: f.id, snapshot: f) }
    }

    @ViewBuilder
    private var emptyState: some View {
        if Shared.location == nil {
            ContentUnavailableView {
                Label("No Location", systemImage: "location.slash")
            } description: {
                Text("Set your location to see the aircraft flying near you.")
            } actions: {
                Button("Open Settings…") { NSApp.sendAction(#selector(AppDelegate.showSettings), to: nil, from: nil) }
            }
        } else if flights.isEmpty && !radar.query.isEmpty {
            ContentUnavailableView.search(text: radar.query)
        } else if flights.isEmpty && !radar.status.isEmpty {
            ContentUnavailableView(radar.status, systemImage: "airplane")
        } else if flights.isEmpty {
            ProgressView()
        }
    }
}

private struct FlightRow: View {
    let f: Flight
    @Environment(\.displayOptions) private var o

    var body: some View {
        HStack(spacing: 10) {
            FlightBadge(f: f, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(f.displayNumber).font(.headline)
                    if let r = f.route {
                        Text("\(r.from.code) → \(r.to.code)").foregroundStyle(.secondary)
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(o.altitude(f.altitude) + (f.climbSymbol.isEmpty ? "" : " \(f.climbSymbol)"))
                Text("\(o.distance(f.distance)) \(f.direction)").font(.caption).foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        [f.airlineName, f.typeCode].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The airline logo, or the aircraft's class symbol when there's no logo to show.
private struct FlightBadge: View {
    let f: Flight
    let size: CGFloat
    @Environment(\.displayOptions) private var o

    var body: some View {
        Group {
            if o.showLogos, AirlineLogos.file(for: f.logoKey?.id) != nil {
                AirlineLogo(code: f.logoKey?.id, size: size)
            } else {
                let kind = AircraftClass(typeCode: f.typeCode)
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.5 * kind.iconScale, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(kind == .rotorcraft ? 0 : -45))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Map

private struct RadarMap: View {
    @ObservedObject var radar: RadarModel
    let radiusNM: Int
    @State private var camera: MapCameraPosition = .automatic
    @Environment(\.displayOptions) private var o
    private var observer: GeoPoint? { Shared.location.map { GeoPoint(lat: $0.lat, lon: $0.lon) } }

    private var framingKey: String {
        "\(observer.map { "\($0.lat),\($0.lon)" } ?? "")|\(radiusNM)"
    }

    var body: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            if let observer {
                // A polygon, not MapCircle: MapCircle stopped the map rendering tiles while on screen.
                MapPolygon(coordinates: FlightMath.removingRepeats(FlightMath.circle(around: observer, radiusNM: Double(radiusNM)))
                    .map(coordinate))
                    .foregroundStyle(Color.blue.opacity(0.05))
                    .stroke(Color.blue.opacity(0.6), lineWidth: 1.5)
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: observer.lat + Double(radiusNM) / 60,
                                                                  longitude: observer.lon), anchor: .center) {
                    Text(o.radius(radiusNM))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.blue.opacity(0.8)))
                }
                Annotation("You", coordinate: coordinate(observer), anchor: .center) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(radius: 1)
                }
            }
            // The selected aircraft is drawn last so it sits on top.
            ForEach(radar.flights.filter { $0.id != radar.selection }) { aircraft($0, selected: false) }
            if let f = radar.flights.first(where: { $0.id == radar.selection }) { aircraft(f, selected: true) }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapZoomStepper()
            MapCompass()
            MapScaleView()
        }
        .overlay(alignment: .topLeading) {
            if observer != nil {
                Button(action: frameRadius) { Image(systemName: "location.circle") }
                    .help("Center on your location")
                    .padding(10)
            }
        }
        .onChange(of: framingKey, initial: true) { frameRadius() }
    }

    private func aircraft(_ f: Flight, selected: Bool) -> some MapContent {
        Annotation("", coordinate: coordinate(f.geoPoint), anchor: .center) {
            AircraftMarker(f: f, selected: selected)
                .onTapGesture(count: 2) { FlightDetail.show(hex: f.id, snapshot: f) }
                .onTapGesture { radar.selection = f.id }
        }
        .annotationTitles(.hidden)
    }

    /// Fits the search-radius circle around the user.
    private func frameRadius() {
        guard let observer else { return }
        let d = Double(radiusNM) / 60 * 1.15
        let span = MKCoordinateSpan(latitudeDelta: d * 2, longitudeDelta: d * 2 / max(0.2, cos(observer.lat * .pi / 180)))
        withAnimation { camera = .region(MKCoordinateRegion(center: coordinate(observer), span: span)) }
    }

    private func coordinate(_ p: GeoPoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
    }
}

/// An aircraft on the radar map: its class symbol rotated to its track, labelled with its flight number.
private struct AircraftMarker: View {
    let f: Flight
    let selected: Bool

    var body: some View {
        let kind = AircraftClass(typeCode: f.typeCode)
        VStack(spacing: 1) {
            Image(systemName: kind.symbol)
                .font(.system(size: (selected ? 24 : 16) * kind.iconScale, weight: .semibold))
                .foregroundStyle(selected ? Color.accentColor : f.looksLikeAirline ? Color.primary : Color.secondary)
                // The symbol points east; the map is always north-up.
                .rotationEffect(.degrees(kind == .rotorcraft ? 0 : (f.track ?? 90) - 90))
                .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 1.5)
            Text(f.displayNumber)
                .font(.system(size: selected ? 11 : 9, weight: selected ? .bold : .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, selected ? 5 : 0)
                .background {
                    if selected { Capsule().fill(Color.accentColor) }
                }
                .shadow(color: selected ? .clear : Color(nsColor: .windowBackgroundColor), radius: 1)
        }
        .contentShape(Rectangle())
        .help("\(f.displayNumber) — double-click for details")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(f.displayNumber)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Inspector

private struct FlightInspector: View {
    @ObservedObject var radar: RadarModel
    @Environment(\.displayOptions) private var o

    var body: some View {
        if let f = radar.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(f)
                    if let r = f.route { route(r, f) }
                    facts(f)
                    if !radar.flights.contains(where: { $0.id == f.id }) {
                        Label("Out of range — last known position", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button { FlightDetail.show(hex: f.id, snapshot: f) } label: {
                        Text("Open Details").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding()
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "airplane", description: Text("Select a flight in the list or on the map."))
        }
    }

    private func header(_ f: Flight) -> some View {
        HStack(spacing: 12) {
            FlightBadge(f: f, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.displayNumber).font(.title2.bold())
                Text(f.airlineName.isEmpty ? (f.looksLikeAirline ? f.callsign : "Private / general aviation") : f.airlineName)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func route(_ r: RouteInfo, _ f: Flight) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                airport(r.from, alignment: .leading)
                Spacer()
                airport(r.to, alignment: .trailing)
            }
            RouteLine(iconSize: 14, progress: f.progress)
            if let p = f.progress {
                Text("\(Int((p * 100).rounded()))% of the way").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func airport(_ a: Airport, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(a.code).font(.title3.weight(.semibold))
            Text(a.city).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func facts(_ f: Flight) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            fact("Altitude", o.altitude(f.altitude) + climb(f))
            fact("Speed", o.speed(f.speed))
            fact("Track", f.track.map { "\(Int($0.rounded()))° \(FlightMath.compassPoint($0))" } ?? "—")
            Divider().gridCellUnsizedAxes(.horizontal)
            fact("Aircraft", f.aircraft?.model ?? (f.typeCode.isEmpty ? "—" : f.typeCode))
            fact("Type", f.typeCode.isEmpty ? "—" : f.typeCode)
            fact("Registration", f.reg)
            if !f.callsign.isEmpty { fact("Callsign", f.callsign) }
            Divider().gridCellUnsizedAxes(.horizontal)
            fact("Distance", o.distance(f.distance))
            fact("Direction", "\(FlightMath.compassPoint(f.bearing)) of you (\(Int(f.bearing.rounded()))°)")
        }
        .font(.callout)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).monospacedDigit()
        }
    }

    private func climb(_ f: Flight) -> String {
        f.verticalRate > 300 ? " · climbing" : f.verticalRate < -300 ? " · descending" : ""
    }
}
