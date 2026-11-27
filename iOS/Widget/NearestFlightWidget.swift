// Lock Screen widgets (circular, rectangular, inline): the nearest flight to your FlightDesk
// location. Tapping opens that flight in the app.

import AppIntents
import SwiftUI
import WidgetKit

struct NearestFlightIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Nearest Flight"
    static let description = IntentDescription("The aircraft closest to you. Options left on “Same as FlightDesk Settings” follow the app.")

    @Parameter(title: "Location",
               description: "A city, airport code or coordinates (“39.7, -104.9”). Leave empty to use the location set in FlightDesk.")
    var location: String?

    @Parameter(title: "Radius", default: .app)
    var radiusChoice: WidgetRadius

    @Parameter(title: "Units", default: .app)
    var unitsChoice: WidgetUnits

    @Parameter(title: "Private & GA", description: "Include light aircraft, helicopters and business jets.", default: .app)
    var includeGAChoice: WidgetToggle
}

struct NearestFlightEntry: TimelineEntry {
    let date: Date
    let state: NearestFlightState
}

struct NearestFlightProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NearestFlightEntry {
        NearestFlightEntry(date: .now, state: .sample)
    }

    func snapshot(for config: NearestFlightIntent, in context: Context) async -> NearestFlightEntry {
        if context.isPreview { return placeholder(in: context) }
        return await timeline(for: config, in: context).entries.first ?? placeholder(in: context)
    }

    func timeline(for config: NearestFlightIntent, in context: Context) async -> Timeline<NearestFlightEntry> {
        let now = Date()
        let s = AppSettings.load()
        let units = config.unitsChoice.resolve(s)
        let radius = config.radiusChoice.resolve(s)
        let includeGA = config.includeGAChoice.resolve(s.includeGA)
        func single(_ status: String, retry: TimeInterval) -> Timeline<NearestFlightEntry> {
            Timeline(entries: [NearestFlightEntry(date: now, state: NearestFlightState(flight: nil, units: units, status: status))],
                     policy: .after(now + retry))
        }

        var loc: (lat: Double, lon: Double, name: String)?
        if let text = config.location?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            loc = await FlightService.resolve(text)
            if loc == nil { return single("Can’t find “\(text)”", retry: 900) }
        } else {
            loc = Shared.location
        }
        guard let loc else { return single("Set a location in FlightDesk", retry: 900) }
        WidgetDemand.record(WidgetArea(lat: loc.lat, lon: loc.lon, radiusNM: radius.nm, includeGA: includeGA))

        let flights: [Flight]
        do {
            flights = try await FlightService.nearby(lat: loc.lat, lon: loc.lon, radiusNM: radius.nm, includeGA: includeGA)
        } catch {
            return single("Can’t reach flight data", retry: 120)
        }
        guard !flights.isEmpty else { return single("Quiet skies", retry: 300) }

        // A frame a minute for 10 minutes, each dead-reckoned from the fetch, so the nearest aircraft
        // and its distance keep moving until WidgetKit next reloads.
        let entries = (0..<10).map { i -> NearestFlightEntry in
            let t = Double(i) * 60
            let moved = flights.map { $0.projected(by: t, observerLat: loc.lat, observerLon: loc.lon) }
            let state = NearestFlightState(flight: NearestFlightText.nearest(moved), units: units, status: "Quiet skies")
            return NearestFlightEntry(date: now + t, state: state)
        }
        return Timeline(entries: entries, policy: .after(now + 600))
    }
}

struct NearestFlightWidgetView: View {
    let entry: NearestFlightEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: NearestCircularView(state: entry.state)
            case .accessoryInline: NearestInlineView(state: entry.state)
            default: NearestRectangularView(state: entry.state)
            }
        }
        .widgetURL(entry.state.flight.flatMap { FlightLink.url(for: $0.id) } ?? URL(string: "\(FlightLink.scheme)://radar"))
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct NearestFlightWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Shared.accessoryWidgetKind, intent: NearestFlightIntent.self, provider: NearestFlightProvider()) {
            NearestFlightWidgetView(entry: $0)
        }
        .configurationDisplayName("Nearest Flight")
        .description("The aircraft closest to you: how far, how high and where it’s going.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
