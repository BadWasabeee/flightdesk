// Navigation for the iPhone app: which tab the sheet shows, its height, and the flight detail.
// Deep links, widget taps, notification taps and Shortcuts all come through here.

import Combine
import SwiftUI

@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    enum TabID: Hashable { case radar, logbook, settings }

    /// The sheet's smallest height: the search field and tab bar over a full-screen map.
    static let peek = PresentationDetent.height(212)
    static let detents: Set<PresentationDetent> = [peek, .medium, .large]

    @Published var tab: TabID = .radar {
        didSet {
            guard tab != oldValue else { return }
            // Logbook and Settings are reading screens: give them room. Back on the radar, show the map again.
            if tab != .radar, detent != .large { detent = .large }
            if tab == .radar, oldValue != .radar, detent == .large { detent = .medium }
        }
    }
    @Published var detent: PresentationDetent = .medium
    @Published var settingsPath: [SettingsTab] = []
    /// Height of the sheet in points, reported by the sheet itself (the map keeps aircraft out from under it).
    @Published var sheetHeight: CGFloat = 0
    /// One-shot camera requests for the map ("Show Whole Flight", "Center on Aircraft", "Near You").
    let mapCommands = PassthroughSubject<MapCommand, Never>()

    enum MapCommand { case wholeFlight, aircraft, nearby }

    private(set) var radar: RadarModel?
    /// Requests that arrived before the radar existed (a cold launch from a widget or notification).
    private var pending: [@MainActor (AppRouter) -> Void] = []

    func attach(_ radar: RadarModel) {
        self.radar = radar
        let queued = pending
        pending = []
        queued.forEach { $0(self) }
    }

    private func whenReady(_ action: @escaping @MainActor (AppRouter) -> Void) {
        if radar != nil { action(self) } else { pending.append(action) }
    }

    // MARK: Destinations

    /// Shows an aircraft's detail in the sheet (selecting it on the map). Never moves the camera
    /// except to pan an aircraft out from under the sheet.
    func showFlight(hex: String, snapshot: Flight? = nil) {
        guard let hex = AircraftID.hex(hex) else { return }
        whenReady { router in
            guard let radar = router.radar else { return }
            router.tab = .radar
            radar.showDetail(hex: hex, snapshot: snapshot)
            if router.detent == AppRouter.peek { router.detent = .medium }
        }
    }

    /// Back to the list and map, closing any detail.
    func showRadar() {
        whenReady { router in
            router.tab = .radar
            router.closeDetail()
        }
    }

    func showLogbook() { whenReady { $0.tab = .logbook } }

    /// Settings, at a sub-page for every tab but General (which is the Settings root on iPhone).
    func showSettings(_ settingsTab: SettingsTab) {
        whenReady { router in
            router.tab = .settings
            router.settingsPath = settingsTab == .general ? [] : [settingsTab]
            router.detent = .large
        }
    }

    /// Closes the detail and clears the selection, so the map is back to the plain radar.
    func closeDetail() {
        radar?.closeDetail()
        radar?.selection = nil
    }

    /// Handles a flightdesk:// link. Returns false for links that aren't FlightDesk's.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let link = AppLink(url: url) else { return false }
        switch link {
        case .flight(let hex): showFlight(hex: hex)
        case .settings(let u): showSettings(SettingsTab(url: u) ?? .general)
        case .radar: showRadar()
        case .logbook: showLogbook()
        }
        return true
    }
}

// MARK: - Entry points shared with the Mac code

/// The iPhone's version of the Mac entry point for showing an aircraft (notifications, the
/// logbook's Show on Radar, VoiceOver actions): always the radar sheet.
@MainActor
enum FlightDetail {
    static func show(hex: String, snapshot: Flight? = nil) {
        AppRouter.shared.showFlight(hex: hex, snapshot: snapshot)
    }
}

/// Connects App Intents to the running app, like the Mac's AppDelegate routing.
@MainActor
enum IntentRouting {
    /// Spoken and Shortcuts answers run without UI; nothing to hold back on iPhone.
    static func answering() {}
    static func showFlight(hex: String) { AppRouter.shared.showFlight(hex: hex) }
    static func showRadar() { AppRouter.shared.showRadar() }
    static func showSettings(_ tab: SettingsTab) { AppRouter.shared.showSettings(tab) }
}
