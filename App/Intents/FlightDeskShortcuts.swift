// Phrases Siri and Spotlight offer without any setup.

import AppIntents

struct FlightDeskShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WhatsFlyingOverheadIntent(), phrases: [
            "What’s flying over me in \(.applicationName)",
            "What’s flying overhead in \(.applicationName)",
            "What plane is above me in \(.applicationName)",
        ], shortTitle: "What’s Overhead", systemImageName: "airplane")
        AppShortcut(intent: NearbyFlightsIntent(), phrases: [
            "Nearby flights in \(.applicationName)",
            "Show nearby flights in \(.applicationName)",
        ], shortTitle: "Nearby Flights", systemImageName: "list.bullet")
        AppShortcut(intent: FindFlightIntent(), phrases: [
            "Find flight in \(.applicationName)",
            "Find a flight in \(.applicationName)",
        ], shortTitle: "Find Flight", systemImageName: "magnifyingglass")
        AppShortcut(intent: OpenRadarIntent(), phrases: [
            "Open radar in \(.applicationName)",
            "Show the radar in \(.applicationName)",
        ], shortTitle: "Open Radar", systemImageName: "dot.radiowaves.left.and.right")
        AppShortcut(intent: OpenSettingsIntent(), phrases: [
            "Open \(.applicationName) settings",
            "Open \(\.$tab) settings in \(.applicationName)",
        ], shortTitle: "Open Settings", systemImageName: "gearshape")
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}
