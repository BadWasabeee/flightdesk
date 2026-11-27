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
/// flight detail shown in place of the map.
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
        detail?.start()
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
            updated = Date()
            feed = fresh.isEmpty ? .empty : .live
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
    }

    /// Looks up route and aircraft details for a newly selected aircraft the store hasn't enriched.
    private func lookUpSelection() {
        guard let f = selected, f.route == nil || f.aircraft == nil, !lookedUp.contains(f.id) else { return }
        lookedUp.insert(f.id)
        Task {
            let found = await FlightDetailService.enrichment(for: f)
            var k = known[f.id] ?? f
            k.route = k.route ?? found.route
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

    /// Shows the detail for the aircraft with `hex` in place of the map, and selects it.
    func showDetail(hex: String, snapshot: Flight?) {
        let id = flights.first { $0.id.caseInsensitiveCompare(hex) == .orderedSame }?.id ?? hex
        guard detail?.hex != id else { return }
        let snap = snapshot ?? flights.first { $0.id == id } ?? detail?.nearby.first { $0.id == id }
        detail?.stop()
        let model = FlightDetailModel(hex: id, snapshot: snap, nearby: flights)
        detailFlight = snap
        detail = model
        detailSubscription = model.$flight.dropFirst().sink { [weak self] f in
            self?.detailFlight = f
            if let self, self.selection == id, !self.flights.contains(where: { $0.id == id }) { self.selected = f }
        }
        if isActive { model.start() }
        if selection != id { selection = id }
    }

    /// Back to the map, keeping the selection.
    func closeDetail() {
        guard let detail else { return }
        detail.stop()
        detailSubscription = nil
        self.detail = nil
        detailFlight = nil
    }

    /// The Esc key: back from a detail, else clear the selection, else clear the search.
    /// Returns false when there was nothing to cancel.
    @discardableResult
    func cancel() -> Bool {
        if detail != nil { closeDetail() } else if selection != nil { selection = nil } else if !query.isEmpty { query = "" } else { return false }
        return true
    }
}

/// The app's main window: nearby aircraft in a sidebar, a live map and an inspector, or the full
/// detail of one flight in place of the map. The window is created when first shown and released
/// when closed (its frame is autosaved). Flight details opened anywhere in the app come here.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    private let store: LiveStore
    private(set) var window: NSWindow?
    private var radar: RadarModel?
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

    /// View › Back (⌘[): from a detail back to the map.
    @objc func goBack(_ sender: Any?) {
        withAnimation(Self.motion) { radar?.closeDetail() }
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
        if radar.sidebar == .detailOnly {
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
        withAnimation(Self.motion) { radar.closeDetail() }
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
            return key && radar?.detail != nil
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
