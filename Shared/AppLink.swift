// Where a flightdesk:// link goes. The Mac's AppDelegate handles flight and settings links itself;
// the iPhone app routes every link through this. Pure Foundation so it can be unit tested.

import Foundation

enum AppLink: Equatable {
    /// flightdesk://flight/<hex>: that aircraft's detail (widgets, alerts, Shortcuts).
    case flight(String)
    /// flightdesk://settings/<tab>: Settings at a tab (the tab is resolved by `SettingsTab(url:)`).
    case settings(URL)
    /// flightdesk://radar: the live map and list.
    case radar
    /// flightdesk://logbook: the spotting log.
    case logbook

    /// The destination of a FlightDesk link, or nil for anything else (including malformed aircraft addresses).
    init?(url: URL) {
        guard url.scheme?.lowercased() == FlightLink.scheme, let host = url.host?.lowercased() else { return nil }
        switch host {
        case "flight":
            guard let hex = FlightLink.hex(from: url) else { return nil }
            self = .flight(hex)
        case "settings": self = .settings(url)
        case "radar", "map": self = .radar
        case "logbook", "log": self = .logbook
        default: return nil
        }
    }
}
