import SwiftUI
import MapKit

/// Main window content: a searchable aircraft list beside either the live radar map (with an
/// inspector for the selection) or the full detail of one flight. Settings replaces both: its
/// tabs fill the sidebar and the selected pane the content area, with Back returning to either.
struct MainWindowView: View {
    @ObservedObject var store: LiveStore
    @ObservedObject var radar: RadarModel

    /// The user's board settings in the Standard look, which follows the system appearance.
    private var display: DisplayOptions {
        var o = store.settings.display
        o.style = .standard
        return o
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $radar.sidebar) {
            Group {
                if radar.settingsTab != nil {
                    SettingsSidebar(radar: radar)
                } else if radar.showsLogbook {
                    LogbookList(model: radar.logbook)
                } else {
                    FlightList(radar: radar,
                               flights: FlightListFilter.apply(radar.flights, query: radar.query, sort: radar.sort),
                               total: radar.flights.count,
                               feed: radar.feed,
                               radius: store.settings.radius,
                               includeGA: store.settings.includeGA,
                               hasLocation: !store.placeName.isEmpty || Shared.location != nil,
                               locationStatus: store.locationStatus)
                        // On the list, not the split view, so Settings' sidebar has no search field.
                        .searchable(text: $radar.query, placement: .sidebar, prompt: "Callsign, reg, type, airport")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter(radar: radar) }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            content
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .onExitCommand {
            // Esc while typing just ends editing; it only navigates back from outside a text field.
            if let window = NSApp.keyWindow, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
                window.makeFirstResponder(nil)
                return
            }
            withAnimation(MainWindowController.motion) { _ = radar.cancel() }
        }
        .environment(\.displayOptions, display)
        .frame(minWidth: 900, minHeight: 600)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        ZStack {
            if let tab = radar.settingsTab {
                SettingsPane(tab: tab, store: store)
                    .transition(.opacity)
            } else if radar.showsLogbook {
                LogbookContent(radar: radar, model: radar.logbook)
                    .transition(.opacity)
            } else if let detail = radar.detail {
                FlightDetailView(model: detail)
                    .id(detail.hex)
                    .environment(\.openFlightDetail) { [radar] f in
                        withAnimation(MainWindowController.motion) { radar.showDetail(hex: f.id, snapshot: f) }
                    }
                    .transition(.opacity)
            } else {
                RadarMap(radar: radar, radiusNM: store.settings.radius.nm, placeName: store.placeName,
                         locationStatus: store.locationStatus)
                    .inspector(isPresented: inspectorShown) {
                        FlightInspector(radar: radar)
                            .inspectorColumnWidth(min: 260, ideal: 290, max: 360)
                    }
                    .transition(.opacity)
            }
        }
    }

    private var inspectorShown: Binding<Bool> {
        Binding(get: { radar.selected != nil }, set: { if !$0 { radar.selection = nil } })
    }

    // MARK: Title

    private var title: String {
        if radar.settingsTab != nil { return "Settings" }
        if radar.showsLogbook { return "Logbook" }
        return detailTitle ?? "FlightDesk"
    }

    /// The shown flight's number (or hex while loading), nil on the map.
    private var detailTitle: String? {
        guard let detail = radar.detail else { return nil }
        let number = radar.detailFlight?.displayNumber ?? ""
        return number.isEmpty ? detail.hex.uppercased() : number
    }

    private var subtitle: String {
        if let tab = radar.settingsTab { return tab.title }
        if radar.showsLogbook { return "Stored only on this Mac" }
        if radar.detail != nil {
            guard let f = radar.detailFlight else { return "Loading…" }
            if let r = f.route, let to = f.destination {
                let route = "\(r.from.city.isEmpty ? r.from.code : r.from.city) → \(to.city.isEmpty ? to.code : to.city)"
                return [route, f.situation?.title].compactMap { $0 }.joined(separator: " · ")
            }
            return [FlightRowText.operatorName(f), f.typeCode].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        guard !store.placeName.isEmpty else { return "No location set" }
        return "\(store.placeName) · \(feedSummary)"
    }

    private var feedSummary: String {
        let radius = display.radius(store.settings.radius.nm)
        switch radar.feed {
        case .loading: return "Looking for aircraft…"
        case .noLocation: return "No location set"
        case .offline: return radar.flights.isEmpty ? "Offline" : "Offline · \(count(radar.flights.count)) last seen"
        case .empty, .live: return "\(count(radar.flights.count)) within \(radius)"
        }
    }

    private func count(_ n: Int) -> String { n == 0 ? "No aircraft" : "\(n) aircraft" }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if radar.settingsTab != nil || radar.showsLogbook || radar.detail != nil {
            ToolbarItem(placement: .navigation) {
                Button { withAnimation(MainWindowController.motion) { _ = radar.goBack() } } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .help(backHelp)
            }
        }
        if radar.settingsTab == nil && radar.showsLogbook {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let log = SpottingLogStore.shared
                    radar.logbook.export(radar.logbook.visible(in: log, db: SpotterAlerts.shared.database))
                } label: {
                    Label("Export CSV…", systemImage: "square.and.arrow.up")
                }
                .help("Export the aircraft shown to a CSV file")
            }
        } else if radar.settingsTab == nil {
            radarActions
        }
    }

    /// Where Back goes: from Settings to the flight or map underneath, from a flight to the map.
    private var backHelp: String {
        if radar.settingsTab != nil, radar.showsLogbook { return "Back to the logbook (⌘[)" }
        if radar.settingsTab != nil, let flight = detailTitle { return "Back to \(flight) (⌘[)" }
        return "Back to the map (⌘[)"
    }

    /// Radius, Airlines Only and Refresh (hidden in Settings, which has its own radius control).
    @ToolbarContentBuilder
    private var radarActions: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Radius", selection: $store.settings.radius) {
                ForEach(SearchRadius.allCases, id: \.self) { Text(display.radius($0.nm)).tag($0) }
            }
            .pickerStyle(.menu)
            .help("Search radius")
            Toggle(isOn: Binding(get: { !store.settings.includeGA }, set: { store.settings.includeGA = !$0 })) {
                Label("Airlines Only", systemImage: "line.3.horizontal.decrease.circle")
            }
            .help(store.settings.includeGA ? "Show only airline flights" : "Show all aircraft, including private and general aviation")
            Button { Task { await radar.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help(refreshHelp)
        }
    }

    private var refreshHelp: String {
        guard let t = radar.updated else { return "Refresh now (⌘R)" }
        return "Refresh now (⌘R) · updated \(t.formatted(date: .omitted, time: .standard))"
    }
}

extension RadarModel {
    /// Opens `f`'s detail in the window, with the window's transition.
    func open(_ f: Flight) {
        withAnimation(MainWindowController.motion) { showDetail(hex: f.id, snapshot: f) }
    }
}

// MARK: - Sidebar

private struct FlightList: View {
    @ObservedObject var radar: RadarModel
    let flights: [Flight]
    let total: Int
    let feed: RadarFeedState
    let radius: SearchRadius
    let includeGA: Bool
    let hasLocation: Bool
    let locationStatus: String
    @ObservedObject private var log = SpottingLogStore.shared
    @Environment(\.displayOptions) private var o
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $radar.selection) {
                if !flights.isEmpty {
                    Section {
                        ForEach(flights) {
                            FlightRow(f: $0, phase: radar.runwayPhases[$0.id],
                                      firstSighting: log.firstTypeSightings.contains($0.id)).tag($0.id)
                        }
                    } header: {
                        header
                    }
                }
            }
            .contextMenu(forSelectionType: Flight.ID.self) { ids in
                if let f = flight(ids) { FlightMenu(f: f, radar: radar) }
            } primaryAction: { ids in
                if let f = flight(ids) { radar.open(f) }
            }
            .onKeyPress(.space) {
                guard let id = radar.selection, let f = radar.flights.first(where: { $0.id == id }) else { return .ignored }
                radar.open(f)
                return .handled
            }
            .onChange(of: radar.selection) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(id) }
            }
            .overlay { emptyState }
        }
    }

    private func flight(_ ids: Set<Flight.ID>) -> Flight? {
        guard let id = ids.first else { return nil }
        return radar.flights.first { $0.id == id } ?? (radar.selected?.id == id ? radar.selected : nil)
    }

    private var header: some View {
        HStack {
            Text(flights.count == total ? "\(total) aircraft" : "\(flights.count) of \(total) aircraft")
                .monospacedDigit()
            Spacer()
            Menu {
                Picker("Sort By", selection: $radar.sort) {
                    ForEach(FlightSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text("Sort: \(radar.sort.title)")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Sort by \(radar.sort.title)")
            .help("Sort the list")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !hasLocation {
            ContentUnavailableView {
                Label("No Location", systemImage: "location.slash")
            } description: {
                Text(locationStatus.isEmpty ? "Choose where you are to see the aircraft flying nearby." : locationStatus)
            } actions: {
                Button("Use Current Location") { radar.store.requestCurrentLocation() }
                Button("Choose a Place…") { (NSApp.delegate as? AppDelegate)?.openSettings(tab: .general) }
            }
        } else if flights.isEmpty && total > 0 {
            ContentUnavailableView.search(text: radar.query)
        } else if flights.isEmpty {
            switch feed {
            case .offline:
                ContentUnavailableView {
                    Label("Can’t Reach the Flight Feed", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("FlightDesk will keep trying.")
                } actions: {
                    Button("Try Again") { Task { await radar.refresh() } }
                }
            case .empty:
                ContentUnavailableView {
                    Label("Quiet Skies", systemImage: "airplane")
                } description: {
                    Text("No aircraft within \(o.radius(radius.nm)) right now.")
                } actions: {
                    if let wider = SearchRadius.allCases.last, wider != radius {
                        Button("Search Within \(o.radius(wider.nm))") { radar.store.settings.radius = wider }
                    }
                    if !includeGA {
                        Button("Include Private & GA") { radar.store.settings.includeGA = true }
                    }
                }
            case .loading, .live, .noLocation:
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for aircraft…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Settings

/// The Settings tabs, in the sidebar while Settings is shown.
private struct SettingsSidebar: View {
    @ObservedObject var radar: RadarModel

    var body: some View {
        List(selection: Binding(get: { radar.settingsTab }, set: { if let tab = $0 { radar.showSettings(tab) } })) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
        }
        .accessibilityLabel("Settings")
    }
}

/// One Settings tab's form, centred at a readable width over a full-bleed background.
private struct SettingsPane: View {
    let tab: SettingsTab
    let store: LiveStore

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettings(store: store)
            case .widget: WidgetSettings(store: store)
            case .alerts: SpotterSettingsView(store: store)
            case .sources: SourcesSettings(store: store)
            }
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: SettingsMetrics.width)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .id(tab)
    }
}

/// Actions for one aircraft (list and map context menus).
private struct FlightMenu: View {
    let f: Flight
    let radar: RadarModel

    var body: some View {
        Button("Open Details") { radar.open(f) }
        Button("Open in New Window") { FlightDetail.showInNewWindow(hex: f.id, snapshot: f) }
        Divider()
        Button("Copy Flight Number") { copy(f.displayNumber) }
        if !f.callsign.isEmpty && f.callsign != f.displayNumber { Button("Copy Callsign") { copy(f.callsign) } }
        if !f.reg.isEmpty { Button("Copy Registration") { copy(f.reg) } }
        Button("Copy ICAO Hex") { copy(f.id.uppercased()) }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - Map

private struct RadarMap: View {
    @ObservedObject var radar: RadarModel
    let radiusNM: Int
    /// Passed so the map redraws when the location changes.
    let placeName: String
    let locationStatus: String
    @State private var camera: MapCameraPosition
    @State private var region: MKCoordinateRegion?
    @State private var mapSize: CGSize = .zero
    @State private var labelled: Set<String> = []
    @State private var hovered: String?
    @Environment(\.displayOptions) private var o
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(radar: RadarModel, radiusNM: Int, placeName: String, locationStatus: String) {
        self.radar = radar
        self.radiusNM = radiusNM
        self.placeName = placeName
        self.locationStatus = locationStatus
        _camera = State(initialValue: radar.mapRegion.map { .region($0) } ?? .automatic)
        _region = State(initialValue: radar.mapRegion)
    }

    private var observer: GeoPoint? { Shared.location.map { GeoPoint(lat: $0.lat, lon: $0.lon) } }

    private var framingKey: String {
        "\(observer.map { "\($0.lat),\($0.lon)" } ?? "")|\(radiusNM)"
    }

    private var motion: Animation? { reduceMotion ? nil : .default }

    /// The selected aircraft's route ahead: along its decoded ACARS route (not during a diversion
    /// or return), else a great circle to where it's going; empty when that's unknown.
    private func aheadPath(of f: Flight) -> [GeoPoint] {
        if let route = radar.acarsRoutes[f.id], f.pathSituation?.newDestination == nil,
           let plan = route.plan(aircraft: f.geoPoint, origin: f.route?.from.geoPoint, destination: f.route?.to.geoPoint) {
            return plan.remaining
        }
        guard f.route != nil, let to = f.destination else { return [] }
        return FlightMath.removingRepeats(FlightMath.greatCircle(from: f.geoPoint, to: to.geoPoint))
    }

    var body: some View {
        let selected = radar.flights.first { $0.id == radar.selection }
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            if let observer {
                // A polygon, not MapCircle: MapCircle stopped the map rendering tiles while on screen.
                MapPolygon(coordinates: FlightMath.removingRepeats(FlightMath.circle(around: observer, radiusNM: Double(radiusNM)))
                    .map(coordinate))
                    .foregroundStyle(Color.blue.opacity(0.04))
                    .stroke(Color.blue.opacity(0.55), lineWidth: 1.5)
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: observer.lat + Double(radiusNM) / 60,
                                                                  longitude: observer.lon), anchor: .center) {
                    Text(o.radius(radiusNM))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.blue.opacity(0.85)))
                        .accessibilityLabel("Search radius \(o.radius(radiusNM))")
                }
                .annotationTitles(.hidden)
                Annotation("You", coordinate: coordinate(observer), anchor: .center) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(radius: 1)
                        .accessibilityLabel("Your location")
                }
            }
            if let selected {
                // Ahead: dashes along the route the aircraft reported over ACARS (when a detail decoded
                // it), else a great circle to the destination. Each dash has a dark rim (its casing is
                // dashed too, with wider round caps) so it reads over land, water and dark mode alike.
                ForEach(Array(RouteGeometry.antimeridianSafe(aheadPath(of: selected)).enumerated()), id: \.offset) { _, ahead in
                    MapPolyline(coordinates: ahead.map(coordinate))
                        .stroke(Color.black.opacity(0.3), style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [7, 7]))
                    MapPolyline(coordinates: ahead.map(coordinate))
                        .stroke(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [7, 7]))
                }
                // Flown: the recorded track (when OpenSky has it), then live positions since selection.
                let flown = FlightMath.removingRepeats(radar.tracks[selected.id, default: []] + radar.trail + [selected.geoPoint])
                if flown.count > 1 {
                    MapPolyline(coordinates: flown.map(coordinate))
                        .stroke(Color.black.opacity(0.3), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    MapPolyline(coordinates: flown.map(coordinate))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
                if let r = selected.route {
                    airport(r.from, role: "Departure")
                    if let s = selected.pathSituation, let to = s.newDestination {
                        airport(r.to, role: "Scheduled destination", struck: true)
                        if to.code != r.from.code { airport(to, role: s.headline) }
                    } else {
                        airport(r.to, role: "Destination")
                    }
                }
            }
            // The selected aircraft is drawn last so it sits on top.
            ForEach(radar.flights.filter { $0.id != radar.selection }) { aircraft($0, selected: false) }
            if let selected { aircraft(selected, selected: true) }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {
            MapZoomStepper()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            region = context.region
            radar.mapRegion = context.region
            relabel()
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { mapSize = geo.size; relabel() }
                    .onChange(of: geo.size) { _, size in mapSize = size; relabel() }
            }
        }
        .overlay(alignment: .topLeading) {
            if observer != nil { recenterButton.padding(10) }
        }
        .overlay(alignment: .top) { MapStatusBanner(feed: radar.feed, hasFlights: !radar.flights.isEmpty, radius: o.radius(radiusNM)).padding(.top, 10) }
        .overlay {
            if observer == nil { NoLocationCard(store: radar.store, status: locationStatus) }
        }
        .onChange(of: framingKey, initial: true) {
            guard radar.framedKey != framingKey else { return }
            radar.framedKey = framingKey
            frameRadius()
        }
        .onChange(of: radar.recenterRequests) { frameRadius() }
        .onChange(of: radar.flights) { relabel() }
        .onChange(of: radar.selection) { _, id in
            relabel()
            reveal(id)
        }
    }

    private var recenterButton: some View {
        Button(action: frameRadius) {
            Image(systemName: "location")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        .help("Center on your location (⌘L)")
        .accessibilityLabel("Center on your location")
    }

    private func aircraft(_ f: Flight, selected: Bool) -> some MapContent {
        Annotation(f.displayNumber, coordinate: coordinate(f.geoPoint), anchor: .center) {
            AircraftMarker(f: f, selected: selected, showsLabel: selected || labelled.contains(f.id) || hovered == f.id)
                .onTapGesture { radar.selection = f.id }
                .simultaneousGesture(TapGesture(count: 2).onEnded { radar.open(f) })
                .onHover { inside in
                    if inside { hovered = f.id } else if hovered == f.id { hovered = nil }
                }
                .contextMenu { FlightMenu(f: f, radar: radar) }
                .accessibilityAction { radar.selection = f.id }
                .accessibilityAction(named: "Open Details") { radar.open(f) }
        }
        .annotationTitles(.hidden)
    }

    /// An origin or destination: a ringed dot with the airport code beneath. `struck` marks a
    /// scheduled destination the flight is no longer heading for.
    private func airport(_ a: Airport, role: String, struck: Bool = false) -> some MapContent {
        Annotation("", coordinate: coordinate(a.geoPoint), anchor: .center) {
            VStack(spacing: 2) {
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2.5))
                Text(a.code)
                    .font(.system(size: 11, weight: .bold))
                    .strikethrough(struck)
                    .foregroundStyle(.primary)
                    .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 1.5)
                    .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 1.5)
            }
            .opacity(struck ? 0.55 : 1)
            // Keep the dot (not the code) on the airport.
            .offset(y: 8)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(role) airport, \(a.code)\(a.city.isEmpty ? "" : ", \(a.city)")")
        }
        .annotationTitles(.hidden)
    }

    /// Picks which aircraft get labels for the current camera, keeping the previous ones where possible.
    private func relabel() {
        guard let r = region, mapSize.width > 0, mapSize.height > 0 else {
            labelled = radar.selection.map { [$0] } ?? []
            return
        }
        let viewport = MapLabelLayout.Viewport(center: GeoPoint(lat: r.center.latitude, lon: r.center.longitude),
                                               latitudeDelta: r.span.latitudeDelta, longitudeDelta: r.span.longitudeDelta,
                                               size: mapSize)
        let items = radar.flights.sorted { $0.distance < $1.distance }
            .map { MapLabelLayout.Item(id: $0.id, point: $0.geoPoint, text: $0.displayNumber) }
        let next = MapLabelLayout.labelled(items, in: viewport, pinned: radar.selection, prefer: labelled)
        if next != labelled { labelled = next }
    }

    /// Pans (keeping the zoom) to an aircraft selected in the list when it's off screen.
    private func reveal(_ id: Flight.ID?) {
        guard let id, let f = radar.flights.first(where: { $0.id == id }), let r = region else { return }
        let inside = abs(f.lat - r.center.latitude) < r.span.latitudeDelta * 0.42
            && abs(f.lon - r.center.longitude) < r.span.longitudeDelta * 0.42
        guard !inside else { return }
        withAnimation(motion) { camera = .region(MKCoordinateRegion(center: coordinate(f.geoPoint), span: r.span)) }
    }

    /// Fits the search-radius circle around the user.
    private func frameRadius() {
        guard let observer else { return }
        let d = Double(radiusNM) / 60 * 1.15
        let span = MKCoordinateSpan(latitudeDelta: d * 2, longitudeDelta: d * 2 / max(0.2, cos(observer.lat * .pi / 180)))
        withAnimation(motion) { camera = .region(MKCoordinateRegion(center: coordinate(observer), span: span)) }
    }

    private func coordinate(_ p: GeoPoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
    }
}

/// Shown over the map until a location is set.
private struct NoLocationCard: View {
    let store: LiveStore
    let status: String

    var body: some View {
        ContentUnavailableView {
            Label("Set Your Location", systemImage: "location.slash")
        } description: {
            Text(status.isEmpty ? "FlightDesk shows the aircraft flying around the place you choose." : status)
        } actions: {
            Button("Use Current Location") { store.requestCurrentLocation() }
                .buttonStyle(.borderedProminent)
            Button("Choose a Place…") { (NSApp.delegate as? AppDelegate)?.openSettings(tab: .general) }
        }
        .frame(maxWidth: 380)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Inspector

private struct FlightInspector: View {
    @ObservedObject var radar: RadarModel
    @Environment(\.displayOptions) private var o

    var body: some View {
        if let f = radar.selected {
            VStack(spacing: 0) {
                header(f)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                Form {
                    if !radar.flights.contains(where: { $0.id == f.id }) {
                        Section {
                            Label("Out of range — last known position", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let s = f.situation {
                        Section {
                            Label(s.title, systemImage: s.symbol)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(s.tint)
                                .accessibilityLabel(s.spoken)
                        }
                    }
                    position(f)
                    if let r = f.route {
                        Section("Route") {
                            route(r, f)
                            DestinationWeatherRow(airport: f.destination ?? r.to, units: o.units)
                        }
                    }
                    Section("Flight") {
                        fact("Altitude", o.altitude(f.altitude))
                        fact("Vertical Speed", FlightRowText.verticalSpeed(f.verticalRate, units: o.units))
                        fact("Ground Speed", o.speed(f.speed))
                        fact("Track", f.track.map { "\(Int($0.rounded()))° \(FlightMath.compassPoint($0))" } ?? "—")
                        if let squawk = f.squawk {
                            LabeledContent("Squawk") {
                                let alert = FlightSituation.squawk(squawk)
                                Text(alert.map { "\(squawk) · \($0.headline)" } ?? squawk)
                                    .monospacedDigit()
                                    .foregroundStyle(alert?.tint ?? Color.primary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    Section("From You") {
                        fact("Distance", o.distance(f.distance))
                        fact("Direction", "\(FlightMath.compassPoint(f.bearing)) · \(Int(f.bearing.rounded()))°")
                    }
                    Section("Aircraft") {
                        if let model = f.aircraft?.model, !model.isEmpty { fact("Model", model) }
                        fact("Type", f.typeCode.isEmpty ? "—" : f.typeCode)
                        fact("Registration", f.reg)
                        if !f.callsign.isEmpty && f.callsign != f.displayNumber { fact("Callsign", f.callsign) }
                        fact("ICAO Hex", f.id.uppercased())
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                Divider()
                Button { radar.open(f) } label: {
                    Text("Open Details").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Show the full flight detail (Return)")
                .padding(12)
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "airplane",
                                   description: Text("Select an aircraft in the list or on the map."))
        }
    }

    /// The position headline ("Final RWY 28C at ORD · 6.0 nm · on glidepath", "Descending through
    /// 6,000 ft") and, on final, the touchdown time; from the phase worked out at the last fetch.
    @ViewBuilder private func position(_ f: Flight) -> some View {
        let phase = radar.runwayPhases[f.id]
        let headline = PositionDescriber.describe(f, phase: phase, options: o).headline
        if !headline.isEmpty {
            Section("Position") {
                Label(headline, systemImage: phase?.symbol ?? "location")
                    .foregroundStyle(phase?.isCaution == true ? Color.orange : Color.primary)
                    .textSelection(.enabled)
                if case .finalApproach(let fa)? = phase {
                    Text(PositionDescriber.touchdown(fa, now: radar.runwayPhasesTime))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func header(_ f: Flight) -> some View {
        HStack(spacing: 12) {
            FlightBadge(f: f, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(FlightRowText.operatorName(f))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(f.displayNumber)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func route(_ r: RouteInfo, _ f: Flight) -> some View {
        VStack(spacing: 8) {
            let to = f.destination ?? r.to
            HStack(alignment: .firstTextBaseline) {
                airport(r.from, alignment: .leading)
                Spacer()
                if let s = f.pathSituation, s.newDestination != nil {
                    // "~~DEN~~ MKE": the scheduled destination struck through beside the new one.
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(r.to.code).font(.callout).strikethrough().foregroundStyle(.secondary)
                        airport(to, alignment: .trailing).foregroundStyle(s.tint)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(s.spoken)
                } else {
                    airport(to, alignment: .trailing)
                }
            }
            RouteLine(iconSize: 12, progress: f.progress)
            let flown = FlightService.gcDistance(r.from.lat, r.from.lon, f.lat, f.lon)
            let left = FlightService.gcDistance(f.lat, f.lon, to.lat, to.lon)
            Text("\(o.distance(flown)) flown · \(o.distance(left)) to go")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func airport(_ a: Airport, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(a.code).font(.title3.weight(.semibold))
            Text(a.city).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }
}

/// One line for the destination's latest METAR: the flight-category dot and the wind. Loaded through
/// the shared `WeatherService` cache (so it costs no request when the detail already has it).
private struct DestinationWeatherRow: View {
    let airport: Airport
    let units: UnitSystem
    @State private var metar: Metar?
    @State private var loadedFor: String?

    var body: some View {
        Group {
            if let m = metar, loadedFor == airport.code {
                LabeledContent("Weather at \(airport.code)") {
                    HStack(spacing: 5) {
                        Circle().fill(m.category?.tint ?? .secondary).frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text([m.category?.rawValue, m.wind.map { WeatherFormat.wind($0, units: units) }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                }
                .help(m.raw)
            }
        }
        .task(id: airport.code) {
            guard let station = WeatherStation.icao(for: airport) else { metar = nil; return }
            // The cache decides when a request is due; this just picks up newer reports.
            while !Task.isCancelled {
                let found = await WeatherService.shared.metars([station])[station]
                guard !Task.isCancelled else { return }
                metar = found
                loadedFor = airport.code
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }
}

/// The sidebar's bottom bar: a Settings button that toggles between Settings and the radar, and
/// a Logbook button that toggles between the logbook and the radar.
private struct SidebarFooter: View {
    @ObservedObject var radar: RadarModel

    var body: some View {
        let inSettings = radar.settingsTab != nil
        let inLogbook = radar.showsLogbook && !inSettings
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button {
                    withAnimation(MainWindowController.motion) {
                        if inSettings { radar.closeSettings() } else { radar.showSettings(radar.lastSettingsTab) }
                    }
                } label: {
                    Label(inSettings ? "Done" : "Settings", systemImage: inSettings ? "checkmark.circle" : "gearshape")
                        .labelStyle(.titleAndIcon)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(inSettings ? (radar.showsLogbook ? "Back to the logbook" : "Back to the radar") : "Settings (⌘,)")
                Spacer()
                Button {
                    withAnimation(MainWindowController.motion) {
                        if inLogbook { radar.closeLogbook() } else { radar.showLogbook() }
                    }
                } label: {
                    Label(inLogbook ? "Radar" : "Logbook", systemImage: inLogbook ? "dot.radiowaves.left.and.right" : "book")
                        .labelStyle(.titleAndIcon)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(inLogbook ? "Back to the radar" : "Every aircraft you’ve seen, kept on this Mac")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(.bar)
    }
}
