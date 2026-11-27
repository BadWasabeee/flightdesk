import Cocoa
import Combine
import MapKit
import SwiftUI

/// Where the radar's data stands, for the window's status text and empty states.
enum RadarFeedState: Equatable {
    /// Before the first fetch has returned.
    case loading
    /// The latest fetch returned aircraft.
    case live
    /// The latest fetch returned nothing in the radius.
    case empty
    /// The latest fetch failed; any aircraft shown are from the last good fetch, dead-reckoned.
    case offline
    /// No location has been set.
    case noLocation
}

/// Live data for the main window: every aircraft in the search radius, refetched every 12 s
/// while the window is on screen and dead-reckoned along its heading in between. Also owns the
/// window's navigation: the flight detail shown in place of the map, and Settings above either.
@MainActor
final class RadarModel: ObservableObject {
    /// All aircraft in the radius, at their estimated current positions.
    @Published private(set) var flights: [Flight] = []
    @Published private(set) var feed = RadarFeedState.loading
    /// When the last fetch succeeded.
    @Published private(set) var updated: Date?
    @Published private(set) var isRefreshing = false
    @Published var selection: Flight.ID? {
        didSet { if selection != oldValue { selectionChanged() } }
    }
    /// The selected aircraft; keeps its last known state after it leaves the radius.
    @Published private(set) var selected: Flight?
    /// Live positions of the selected aircraft since it was selected, oldest first.
    @Published private(set) var trail: [GeoPoint] = []
    /// Recorded tracks by hex, oldest point first. Only the selected aircraft's is fetched (the
    /// OpenSky anonymous quota is small), at most once per selection.
    @Published private(set) var tracks: [String: [GeoPoint]] = [:]
    /// Runway phases of flights below `ApproachAnalyzer.listCeilingFt`, by hex, worked out once per
    /// fetch (not per dead-reckoned frame).
    @Published private(set) var runwayPhases: [String: RunwayPhase] = [:]
    /// When `runwayPhases` was worked out (the reference for touchdown times).
    private(set) var runwayPhasesTime = Date()
    /// Routes decoded from ACARS by a detail shown in this window, by hex (kept after it closes).
    @Published private(set) var acarsRoutes: [String: AcarsRoute] = [:]
    @Published var query = ""
    @Published var sort: FlightSort {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: Self.sortKey) }
    }
    @Published var sidebar: NavigationSplitViewVisibility = .all
    /// The flight detail shown instead of the map, if any.
    @Published private(set) var detail: FlightDetailModel?
    /// The detail's live flight (mirrored so the window title can follow it).
    @Published private(set) var detailFlight: Flight?
    /// Bumped to ask the map to frame the search radius again.
    @Published private(set) var recenterRequests = 0
    /// The Settings pane shown in place of the map or detail, if any.
    @Published private(set) var settingsTab: SettingsTab?

    /// The map's last camera region, kept so the map comes back where it was after a detail.
    var mapRegion: MKCoordinateRegion?
    /// Location and radius the map was last framed for.
    var framedKey: String?

    let store: LiveStore
    /// The latest fetch, before merging and projection.
    private var live: [Flight] = []
    /// When `live` last changed. The feed is cached for 20 s, so a refetch can return the same data.
    private var liveTime = Date.distantPast
    /// Route/aircraft details by hex, from the store's enriched flights and selection lookups.
    private var known: [String: Flight] = [:]
    private var lookedUp: Set<String> = []
    private var refreshAgain = false
    private var poll: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var detailSubscription: AnyCancellable?
    private var acarsRouteSubscription: AnyCancellable?
    /// Sidebar visibility before Settings opened (Settings always shows its sidebar), restored on leaving.
    private var sidebarBeforeSettings: NavigationSplitViewVisibility?
    private var trackTask: Task<Void, Never>?

    private static let fetchEvery = 4
    private static let tick: Duration = .seconds(3)
    private static let sortKey = "radar.sort"
    private static let trailLimit = 300

    init(store: LiveStore) {
        self.store = store
        sort = UserDefaults.standard.string(forKey: Self.sortKey).flatMap(FlightSort.init(rawValue:)) ?? .distance
        if Shared.location == nil { feed = .noLocation }
        // @Published sinks fire before the new value is stored, so act on the next turn.
        store.$model.map(\.flights).removeDuplicates()
            .sink { [weak self] in self?.absorb($0) }
            .store(in: &subscriptions)
        store.$settings.map { "\($0.radius.nm)|\($0.includeGA)" }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in Task { await self?.refreshIfActive() } }
            .store(in: &subscriptions)
        store.$placeName.removeDuplicates().dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.selection = nil
                self.live = []
                self.feed = .loading
                self.publish()
                Task { await self.refreshIfActive() }
            }
            .store(in: &subscriptions)
    }

    var isActive: Bool { poll != nil }

    /// Starts or stops polling (and the detail's polling); the window turns it on while it's visible.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        guard active else {
            poll?.cancel(); poll = nil
            detail?.stop()
            return
        }
        if settingsTab == nil { detail?.start() }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                for _ in 0..<Self.fetchEvery {
                    try? await Task.sleep(for: Self.tick)
                    guard !Task.isCancelled, let self else { return }
                    self.publish()
                }
            }
        }
        loadSelectedTrack()
    }

    /// Fetches now. A request made while one is in flight runs again once it finishes, so a
    /// radius or location change is never lost.
    func refresh() async {
        if isRefreshing { refreshAgain = true; return }
        isRefreshing = true
        repeat {
            refreshAgain = false
            await fetch()
        } while refreshAgain
        isRefreshing = false
    }

    func recenter() { recenterRequests += 1 }

    private func refreshIfActive() async {
        if isActive { await refresh() }
    }

    private func fetch() async {
        guard let loc = Shared.location else {
            live = []
            feed = .noLocation
            publish()
            return
        }
        let settings = store.settings
        do {
            let fresh = try await FlightService.nearby(lat: loc.lat, lon: loc.lon, radiusNM: settings.radius.nm,
                                                       includeGA: settings.includeGA, limit: 250, enrich: 0)
            if fresh != live { live = fresh; liveTime = Date() }
            let ids = Set(fresh.map(\.id))
            known = known.filter { ids.contains($0.key) }
            lookedUp.formIntersection(ids)
            tracks = tracks.filter { ids.contains($0.key) || $0.key == selection }
            updated = Date()
            feed = fresh.isEmpty ? .empty : .live
            let phases = RunwayPhase.listPhases(for: FlightListFilter.merging(fresh, known: known), previous: runwayPhases,
                                                phase: ApproachAnalyzer.listPhase)
            runwayPhasesTime = liveTime
            if phases != runwayPhases { runwayPhases = phases }
            if let id = selection, let f = fresh.first(where: { $0.id == id }), trail.last != f.geoPoint {
                trail = Array((trail + [f.geoPoint]).suffix(Self.trailLimit))
            }
        } catch {
            feed = .offline
        }
        publish()
    }

    /// Remembers route and aircraft details from the store's enriched flights.
    private func absorb(_ enriched: [Flight]) {
        for f in enriched where f.route != nil || f.aircraft != nil { known[f.id] = f }
        publish()
    }

    private func selectionChanged() {
        selected = flights.first { $0.id == selection } ?? (selection != nil && selection == detail?.hex ? detailFlight : nil)
        trail = live.first { $0.id == selection }.map { [$0.geoPoint] } ?? []
        // Picking another aircraft in the list while a detail is open switches the detail to it.
        if let id = selection, detail != nil, id != detail?.hex { showDetail(hex: id, snapshot: nil) }
        lookUpSelection()
        trackTask?.cancel()
        trackTask = nil
        loadSelectedTrack()
    }

    /// Fetches the selected aircraft's recorded track for the map's flown path, unless it's cached,
    /// already loading, or the map isn't showing (the detail fetches its own).
    private func loadSelectedTrack() {
        guard isActive, let f = selected, tracks[f.id] == nil, trackTask == nil, detail == nil, settingsTab == nil else { return }
        let id = f.id
        trackTask = Task { [weak self] in
            let track = await FlightDetailService.track(hex: id, current: f.geoPoint)
            guard let self, !Task.isCancelled else { return }
            self.trackTask = nil
            guard let track, self.selection == id else { return }
            self.tracks[id] = track.points.map(\.point)
            // The track's departure airport can correct the route: here, and (shared) everywhere else.
            let scheduled = await LookupCache.shared.cachedRoute(f.callsign)
            await FlightService.learnRoute(from: track, for: f, scheduled: scheduled)
            self.applyRoute(await FlightService.verifiedRoute(scheduled, for: f), to: f)
        }
    }

    /// Replaces the remembered route (and any diversion) for `f` with a fresh resolution.
    private func applyRoute(_ r: RouteResolution, to f: Flight) {
        var k = known[f.id] ?? f
        k.route = r.route
        k.pathSituation = r.situation
        known[f.id] = k
        publish()
    }

    /// Looks up route and aircraft details for a newly selected aircraft the store hasn't enriched.
    private func lookUpSelection() {
        guard let f = selected, f.route == nil || f.aircraft == nil, !lookedUp.contains(f.id) else { return }
        lookedUp.insert(f.id)
        Task {
            let found = await FlightDetailService.enrichment(for: f)
            let resolved = await FlightService.verifiedRoute(found.route, for: f)
            var k = known[f.id] ?? f
            if k.route == nil {
                k.route = resolved.route
                k.pathSituation = resolved.situation
            }
            k.aircraft = k.aircraft ?? found.aircraft
            known[f.id] = k
            publish()
        }
    }

    private func publish() {
        let merged = FlightListFilter.merging(live, known: known)
        let age = min(60, Date().timeIntervalSince(liveTime))
        let next: [Flight]
        if let o = Shared.location {
            next = merged.map { $0.projected(by: age, observerLat: o.lat, observerLon: o.lon) }
        } else {
            next = merged
        }
        if next != flights { flights = next }
        if let id = selection, let f = flights.first(where: { $0.id == id }), f != selected { selected = f }
    }

    // MARK: Detail

    /// Shows the detail for the aircraft with `hex` in place of the map (leaving Settings), and selects it.
    func showDetail(hex: String, snapshot: Flight?) {
        let id = flights.first { $0.id.caseInsensitiveCompare(hex) == .orderedSame }?.id ?? hex
        guard detail?.hex != id else { closeSettings(); return }
        let snap = snapshot ?? flights.first { $0.id == id } ?? detail?.nearby.first { $0.id == id }
        detail?.stop()
        let model = FlightDetailModel(hex: id, snapshot: snap, nearby: flights)
        detailFlight = snap
        detail = model
        detailSubscription = model.$flight.dropFirst().sink { [weak self] f in
            guard let self else { return }
            self.detailFlight = f
            // The list and map show the route (and diversion) the detail resolved.
            if let f, f.route != self.known[id]?.route || f.pathSituation != self.known[id]?.pathSituation {
                self.known[id] = f
                self.publish()
            }
            if self.selection == id, !self.flights.contains(where: { $0.id == id }) { self.selected = f }
        }
        acarsRouteSubscription = model.$acarsRoute.compactMap { $0 }.sink { [weak self] route in
            self?.remember(route, for: id)
        }
        if selection != id { selection = id }
        closeSettings()
        if isActive { model.start() }
    }

    /// Keeps the newest few decoded routes, so the map can draw the selected aircraft's.
    private func remember(_ route: AcarsRoute, for id: String) {
        var routes = acarsRoutes
        routes[id] = route
        if routes.count > 20, let oldest = routes.min(by: { $0.value.updated < $1.value.updated })?.key { routes[oldest] = nil }
        acarsRoutes = routes
    }

    /// Back to the map, keeping the selection.
    func closeDetail() {
        guard let detail else { return }
        detail.stop()
        detailSubscription = nil
        acarsRouteSubscription = nil
        self.detail = nil
        detailFlight = nil
        loadSelectedTrack()
    }

    // MARK: Settings

    /// Shows Settings at `tab` above whatever the window was showing; the detail underneath pauses.
    /// The Settings tab last shown, reopened by the sidebar's Settings button.
    private(set) var lastSettingsTab = SettingsTab.general

    func showSettings(_ tab: SettingsTab) {
        if settingsTab == nil {
            detail?.stop()
            sidebarBeforeSettings = sidebar
            sidebar = .all
        }
        settingsTab = tab
        lastSettingsTab = tab
    }

    /// Back from Settings to the map or detail it was opened over.
    func closeSettings() {
        guard settingsTab != nil else { return }
        settingsTab = nil
        if let previous = sidebarBeforeSettings { sidebar = previous }
        sidebarBeforeSettings = nil
        if isActive { detail?.start() }
        loadSelectedTrack()
    }

    /// The back action (toolbar chevron, ⌘[): Settings first, then a detail. Returns false when
    /// there was nowhere to go back to.
    @discardableResult
    func goBack() -> Bool {
        if settingsTab != nil { closeSettings() } else if detail != nil { closeDetail() } else { return false }
        return true
    }

    /// The Esc key: back from Settings or a detail, else clear the selection, else clear the search.
    /// Returns false when there was nothing to cancel.
    @discardableResult
    func cancel() -> Bool {
        if goBack() { return true }
        if selection != nil { selection = nil } else if !query.isEmpty { query = "" } else { return false }
        return true
    }
}

/// The app's main window: nearby aircraft in a sidebar, a live map and an inspector, or the full
/// detail of one flight in place of the map, or Settings. The window is created when first shown
/// and released when closed (its frame is autosaved). Flight details and Settings opened anywhere
/// in the app come here.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    private let store: LiveStore
    private(set) var window: NSWindow?
    private var radar: RadarModel?
    /// The Settings tab last shown, reopened by ⌘, (kept across window closes).
    private var lastSettingsTab = SettingsTab.general
    private var tabSubscription: AnyCancellable?
    private static let autosaveName = "FlightDeskMainWindow"

    init(store: LiveStore) {
        self.store = store
        super.init()
        FlightDetail.presenter = { [weak self] hex, snapshot in self?.showDetail(hex: hex, snapshot: snapshot) }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    @objc func showWindow(_ sender: Any?) {
        if window == nil { makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(sender)
        radar?.setActive(true)
    }

    /// Opens the main window on the detail of the aircraft with `hex` (deep links, alerts, panel).
    func showDetail(hex: String, snapshot: Flight?) {
        showWindow(nil)
        let snap = snapshot ?? store.model.flights.first { $0.id.caseInsensitiveCompare(hex) == .orderedSame }
        withAnimation(Self.motion) { radar?.showDetail(hex: hex, snapshot: snap) }
    }

    /// Opens the main window on the live map, leaving Settings and any flight detail (Shortcuts' Open Radar).
    func showRadar() {
        showWindow(nil)
        guard let radar else { return }
        withAnimation(Self.motion) {
            radar.closeSettings()
            radar.closeDetail()
        }
    }

    /// Opens the main window on Settings at `tab`, or at the tab last shown.
    func showSettings(_ tab: SettingsTab? = nil) {
        showWindow(nil)
        guard let radar else { return }
        let tab = tab ?? lastSettingsTab
        let entering = radar.settingsTab == nil
        withAnimation(Self.motion) { radar.showSettings(tab) }
        // Don't drop the cursor into the pane's first text field; Tab moves into it.
        if entering { DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) } }
    }

    /// The window's view transitions, or none with Reduce Motion.
    static var motion: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    // MARK: Actions

    /// View › Refresh: refetches the map's aircraft and the store (panel and widgets).
    @objc func refresh(_ sender: Any?) {
        if let radar { Task { await radar.refresh() } }
        Task { await store.refresh() }
    }

    @objc func toggleFlightList(_ sender: Any?) {
        guard let radar else { return }
        withAnimation(Self.motion) { radar.sidebar = radar.sidebar == .detailOnly ? .all : .detailOnly }
    }

    /// File › Open Details: the selected aircraft's detail, in the window.
    @objc func openSelectedDetails(_ sender: Any?) {
        guard let radar, let id = radar.selection else { return }
        withAnimation(Self.motion) { radar.showDetail(hex: id, snapshot: radar.selected) }
    }

    /// File › Open in New Window: the selected (or shown) aircraft in a separate detail window.
    @objc func openSelectedInNewWindow(_ sender: Any?) {
        guard let radar, let id = radar.detail?.hex ?? radar.selection else { return }
        FlightDetail.showInNewWindow(hex: id, snapshot: radar.detail == nil ? radar.selected : radar.detailFlight)
    }

    /// View › Back (⌘[): from Settings to the map or detail, or from a detail to the map.
    @objc func goBack(_ sender: Any?) {
        withAnimation(Self.motion) { _ = radar?.goBack() }
    }

    /// Esc, when nothing in the window handled it.
    @objc func cancelOperation(_ sender: Any?) {
        withAnimation(Self.motion) { _ = radar?.cancel() }
    }

    /// Edit › Find (⌘F): focuses the sidebar's search field, showing the sidebar if needed.
    @objc func focusSearch(_ sender: Any?) {
        guard let radar, let window else { return }
        let focus = { [weak window] in
            guard let window, let field = Self.searchField(in: window.contentView?.superview ?? window.contentView) else { return }
            window.makeFirstResponder(field)
        }
        if radar.settingsTab != nil || radar.sidebar == .detailOnly {
            withAnimation(Self.motion) { radar.closeSettings() }
            radar.sidebar = .all
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                focus()
            }
        } else {
            focus()
        }
    }

    /// View › Sort By (the item's tag indexes `FlightSort.allCases`).
    @objc func setSort(_ sender: NSMenuItem) {
        guard FlightSort.allCases.indices.contains(sender.tag) else { return }
        radar?.sort = FlightSort.allCases[sender.tag]
    }

    /// View › Airlines Only.
    @objc func toggleAirlinesOnly(_ sender: Any?) { store.settings.includeGA.toggle() }

    /// View › Center on My Location (⌘L).
    @objc func recenter(_ sender: Any?) {
        guard let radar else { return }
        withAnimation(Self.motion) {
            radar.closeSettings()
            radar.closeDetail()
        }
        radar.recenter()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let key = window?.isKeyWindow == true
        switch item.action {
        case #selector(toggleFlightList(_:)):
            item.title = radar?.sidebar == .detailOnly ? "Show Sidebar" : "Hide Sidebar"
            return key
        case #selector(openSelectedDetails(_:)):
            return key && radar?.selection != nil && radar?.selection != radar?.detail?.hex
        case #selector(openSelectedInNewWindow(_:)):
            return key && (radar?.detail != nil || radar?.selection != nil)
        case #selector(goBack(_:)):
            return key && (radar?.detail != nil || radar?.settingsTab != nil)
        case #selector(focusSearch(_:)):
            return key
        case #selector(setSort(_:)):
            item.state = radar.map { FlightSort.allCases.firstIndex(of: $0.sort) == item.tag } == true ? .on : .off
            return key
        case #selector(toggleAirlinesOnly(_:)):
            item.state = store.settings.includeGA ? .off : .on
            return true
        case #selector(recenter(_:)):
            return key && Shared.location != nil
        default:
            return true
        }
    }

    private static func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        for sub in view.subviews { if let f = searchField(in: sub) { return f } }
        return nil
    }

    // MARK: Window

    private func makeWindow() {
        let radar = RadarModel(store: store)
        let host = NSHostingController(rootView: MainWindowView(store: store, radar: radar))
        host.sizingOptions = [.minSize]
        host.sceneBridgingOptions = [.toolbars, .title]
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = host
        w.title = "FlightDesk"
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.delegate = self
        if !w.setFrameUsingName(Self.autosaveName) {
            w.setContentSize(NSSize(width: 1120, height: 720))
            w.center()
        }
        w.setFrameAutosaveName(Self.autosaveName)
        window = w
        self.radar = radar
        tabSubscription = radar.$settingsTab.compactMap { $0 }.sink { [weak self] in self?.lastSettingsTab = $0 }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        radar?.setActive(window.occlusionState.contains(.visible))
    }

    func windowWillClose(_ notification: Notification) {
        radar?.setActive(false)
        radar?.closeDetail()
        radar = nil
        window = nil
    }
}

extension AppDelegate {
    /// Shows the main window (status menu, Dock and launch).
    @objc func showMainWindow() { mainWindow.showWindow(nil) }
}

/// How the app was started.
enum LaunchContext {
    /// True when macOS opened the app as a login item. Only meaningful while launching, when the
    /// "open application" Apple event is current.
    static var isLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}
