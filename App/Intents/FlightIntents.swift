// Siri and Shortcuts actions. The answers ("What's Flying Overhead", "Nearby Flights", "Find
// Flight") run without opening a window; the open actions show the main window, the same one
// `flightdesk://` links use, never a new one.

import AppIntents
#if os(macOS)
import AppKit
#endif
import SwiftUI

// MARK: - Answers

struct WhatsFlyingOverheadIntent: AppIntent {
    static let title: LocalizedStringResource = "What’s Flying Overhead"
    static let description = IntentDescription(
        "Tells you about the aircraft nearest to your FlightDesk location: who it is, where it’s going, where it is and how high, in the units chosen in Settings.",
        categoryName: "Flights")

    @Parameter(title: "Flights", description: "How many nearby flights to return.", default: 3, inclusiveRange: (1, 10))
    var count: Int

    static var parameterSummary: some ParameterSummary {
        Summary("What’s flying overhead (up to \(\.$count) flights)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[FlightEntity]> & ProvidesDialog & ShowsSnippetView {
        await IntentRouting.answering()
        let nearby = try await IntentFlights.nearby(limit: max(count, 4))
        let units = nearby.area.units
        let text = FlightSpeech.overhead(nearby.flights, radiusNM: nearby.radiusNM, units: units)
        let entities = FlightEntity.from(Array(nearby.flights.prefix(count)), units: units)
        return .result(value: entities, dialog: IntentDialog("\(text)"),
                       view: FlightsSnippetView(flights: Array(entities.prefix(3)), place: nearby.area.name))
    }
}

struct NearbyFlightsIntent: AppIntent {
    static let title: LocalizedStringResource = "Nearby Flights"
    static let description = IntentDescription(
        "Returns the flights nearest to your FlightDesk location, nearest first. Private and GA traffic follows Settings.",
        categoryName: "Flights")

    @Parameter(title: "Maximum", description: "The most flights to return.", default: 5, inclusiveRange: (1, 25))
    var count: Int

    @Parameter(title: "Radius", description: "Only flights within this distance. Leave empty to use the radius in Settings (at most 100 nm).")
    var radius: Measurement<UnitLength>?

    static var parameterSummary: some ParameterSummary {
        Summary("Get up to \(\.$count) nearby flights") { \.$radius }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[FlightEntity]> & ProvidesDialog & ShowsSnippetView {
        await IntentRouting.answering()
        let nm = radius.map { min(100, max(0.5, $0.converted(to: .nauticalMiles).value)) }
        let nearby = try await IntentFlights.nearby(limit: count, radiusNM: nm)
        let units = nearby.area.units
        let entities = FlightEntity.from(nearby.flights, units: units)
        let text = FlightSpeech.nearbyCount(entities.count, radiusNM: nearby.radiusNM, units: units)
        return .result(value: entities, dialog: IntentDialog("\(text)"),
                       view: FlightsSnippetView(flights: Array(entities.prefix(5)), place: nearby.area.name))
    }
}

struct FindFlightIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Flight"
    static let description = IntentDescription(
        "Finds a flight FlightDesk can currently see by its callsign (UAL1543), flight number (UA1543), registration (N12345) or ICAO hex address (a1b2c3).",
        categoryName: "Flights")

    @Parameter(title: "Flight", description: "Callsign, flight number, registration or hex address.",
               requestValueDialog: "Which flight? Say its callsign or registration.")
    var query: String

    static var parameterSummary: some ParameterSummary { Summary("Find \(\.$query) nearby") }

    func perform() async throws -> some IntentResult & ReturnsValue<FlightEntity?> & ProvidesDialog {
        await IntentRouting.answering()
        let (flight, area) = try await IntentFlights.find(query)
        guard let flight else {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return .result(value: nil, dialog: "FlightDesk can’t see \(q) near \(area.name.isEmpty ? "you" : area.name) right now.")
        }
        let entity = FlightEntity(flight: flight, units: area.units)
        return .result(value: entity, dialog: IntentDialog("\(entity.summary)"))
    }
}

// MARK: - Open the app

/// Shows a flight's detail in the main window (the open variant of Find Flight).
struct OpenFlightIntent: OpenIntent {
    static let title: LocalizedStringResource = "Show Flight in FlightDesk"
    static let description = IntentDescription("Opens the flight’s details in the FlightDesk window.", categoryName: "Open")

    @Parameter(title: "Flight", description: "A nearby flight; type a callsign, flight number, registration or hex to search.")
    var target: FlightEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouting.showFlight(hex: target.id)
        return .result()
    }
}

struct OpenRadarIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Radar"
    static let description = IntentDescription("Opens the FlightDesk window on the live map.", categoryName: "Open")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouting.showRadar()
        return .result()
    }
}

/// A Settings tab, as `flightdesk://settings/<tab>` names them.
enum SettingsTabOption: String, AppEnum {
    case general, widget, alerts, sources
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Settings Tab"
    static let caseDisplayRepresentations: [SettingsTabOption: DisplayRepresentation] = [
        .general: "General", .widget: "Widget", .alerts: "Alerts", .sources: "Sources",
    ]
}

struct OpenSettingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Settings"
    static let description = IntentDescription("Opens FlightDesk Settings at a tab.", categoryName: "Open")
    static let openAppWhenRun = true

    @Parameter(title: "Tab", default: .general)
    var tab: SettingsTabOption

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$tab) settings") }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouting.showSettings(SettingsTab(rawValue: tab.rawValue) ?? .general)
        return .result()
    }
}

// MARK: - Routing into the app

// The iPhone's IntentRouting lives in iOS/App/AppRouter.swift.
#if os(macOS)
/// Connects intents to the running app, as the `flightdesk://` handlers in `AppDelegate` do.
@MainActor
enum IntentRouting {
    private static var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    /// A spoken or Shortcuts answer is running: if it launched FlightDesk, don't open the main window.
    static func answering() { app?.intentWillAnswer() }

    /// The flight's detail in the main window (Back returns to the map).
    static func showFlight(hex: String) {
        guard let hex = AircraftID.hex(hex) else { return }
        app?.performIntent { $0.mainWindow.showDetail(hex: hex, snapshot: nil) }
    }

    static func showRadar() { app?.performIntent { $0.mainWindow.showRadar() } }

    static func showSettings(_ tab: SettingsTab) { app?.performIntent { $0.openSettings(tab: tab) } }
}
#endif
