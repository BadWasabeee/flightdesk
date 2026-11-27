import Cocoa
import Combine
import SwiftUI

/// Live data for the main window: every aircraft in the search radius, refetched every 12 s
/// while the window is on screen and dead-reckoned along its heading in between.
@MainActor
final class RadarModel: ObservableObject {
    /// All aircraft in the radius, at their estimated current positions.
    @Published private(set) var flights: [Flight] = []
    @Published private(set) var status = ""
    @Published private(set) var updated: Date?
    @Published private(set) var isRefreshing = false
    @Published var selection: Flight.ID? {
        didSet { if selection != oldValue { selectionChanged() } }
    }
    /// The selected aircraft; keeps its last known state after it leaves the radius.
    @Published private(set) var selected: Flight?
    @Published var query = ""
    @Published var sort: FlightSort = .distance
    @Published var sidebar: NavigationSplitViewVisibility = .all

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

    private static let fetchEvery = 4
    private static let tick: Duration = .seconds(3)

    init(store: LiveStore) {
        self.store = store
        // @Published sinks fire before the new value is stored, so act on the next turn.
        store.$model.map(\.flights).removeDuplicates()
            .sink { [weak self] in self?.absorb($0) }
            .store(in: &subscriptions)
        store.$settings.map { "\($0.radius.nm)|\($0.includeGA)" }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in Task { await self?.refreshIfActive() } }
            .store(in: &subscriptions)
        store.$placeName.removeDuplicates().dropFirst()
            .sink { [weak self] _ in
                self?.selection = nil
                Task { await self?.refreshIfActive() }
            }
            .store(in: &subscriptions)
    }

    /// Starts or stops polling; the window turns it on while it's visible.
    func setActive(_ active: Bool) {
        guard active != (poll != nil) else { return }
        guard active else { poll?.cancel(); poll = nil; return }
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

    private func refreshIfActive() async {
        if poll != nil { await refresh() }
    }

    private func fetch() async {
        guard let loc = Shared.location else {
            live = []
            status = "No location set"
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
            status = fresh.isEmpty ? "Nothing within \(settings.display.radius(settings.radius.nm)) right now" : ""
        } catch {
            status = "Can't reach the flight feed — retrying"
        }
        publish()
    }

    /// Remembers route and aircraft details from the store's enriched flights.
    private func absorb(_ enriched: [Flight]) {
        for f in enriched where f.route != nil || f.aircraft != nil { known[f.id] = f }
        publish()
    }

    /// Looks up route and aircraft details for a newly selected aircraft the store hasn't enriched.
    private func selectionChanged() {
        selected = flights.first { $0.id == selection }
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
        if let o = Shared.location {
            flights = merged.map { $0.projected(by: age, observerLat: o.lat, observerLon: o.lon) }
        } else {
            flights = merged
        }
        if let id = selection, let f = flights.first(where: { $0.id == id }) { selected = f }
    }
}

/// The app's main window: nearby flights in a sidebar, a live map and an inspector.
/// The window is created when first shown and released when closed (its frame is autosaved).
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    private let store: LiveStore
    private(set) var window: NSWindow?
    private var radar: RadarModel?
    private static let autosaveName = "FlightDeskMainWindow"

    init(store: LiveStore) {
        self.store = store
    }

    var isVisible: Bool { window?.isVisible ?? false }

    @objc func showWindow(_ sender: Any?) {
        if window == nil { makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(sender)
        radar?.setActive(true)
    }

    /// View › Refresh: refetches the map's aircraft and the store (panel and widgets).
    @objc func refresh(_ sender: Any?) {
        if let radar { Task { await radar.refresh() } }
        Task { await store.refresh() }
    }

    @objc func toggleFlightList(_ sender: Any?) {
        guard let radar else { return }
        withAnimation { radar.sidebar = radar.sidebar == .detailOnly ? .all : .detailOnly }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(toggleFlightList(_:)) else { return true }
        let shown = radar?.sidebar != .detailOnly
        item.title = shown ? "Hide Sidebar" : "Show Sidebar"
        return window?.isKeyWindow == true
    }

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
