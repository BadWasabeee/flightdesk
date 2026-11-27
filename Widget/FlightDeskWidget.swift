// Native macOS desktop widget (WidgetKit) with per-widget configuration via "Edit Widget".

import WidgetKit
import SwiftUI
import AppIntents

enum WidgetRadius: String, AppEnum {
    case app, nm5 = "5", nm10 = "10", nm25 = "25", nm50 = "50", nm100 = "100"
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Radius"
    static var caseDisplayRepresentations: [WidgetRadius: DisplayRepresentation] = [
        .app: "Same as FlightDesk Settings", .nm5: "5 nm (9 km)", .nm10: "10 nm (19 km)",
        .nm25: "25 nm (46 km)", .nm50: "50 nm (93 km)", .nm100: "100 nm (185 km)",
    ]
    func resolve(_ s: AppSettings) -> SearchRadius { self == .app ? s.radius : SearchRadius(rawValue: rawValue) ?? s.radius }
}

enum WidgetTheme: String, AppEnum {
    case app, amber, green, red, blue, cyan, white
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "LED Color"
    static var caseDisplayRepresentations: [WidgetTheme: DisplayRepresentation] = [
        .app: "Same as FlightDesk Settings", .amber: "Amber", .green: "Green", .red: "Red",
        .blue: "Blue", .cyan: "Cyan", .white: "White",
    ]
    func resolve(_ s: AppSettings) -> LEDTheme { LEDTheme(rawValue: rawValue) ?? s.display.theme }
}

enum WidgetStyle: String, AppEnum {
    case app, led, standard
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Style"
    static var caseDisplayRepresentations: [WidgetStyle: DisplayRepresentation] = [
        .app: "Same as FlightDesk Settings", .led: "LED Board", .standard: "Standard",
    ]
    func resolve(_ s: AppSettings) -> BoardStyle { BoardStyle(rawValue: rawValue) ?? s.display.style }
}

enum WidgetUnits: String, AppEnum {
    case app, imperial, metric
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Units"
    static var caseDisplayRepresentations: [WidgetUnits: DisplayRepresentation] = [
        .app: "Same as FlightDesk Settings", .imperial: "Aviation (ft, kt, nm)", .metric: "Metric (m, km/h, km)",
    ]
    func resolve(_ s: AppSettings) -> UnitSystem { UnitSystem(rawValue: rawValue) ?? s.display.units }
}

/// Per-widget overrides shown in "Edit Widget". Everything else comes from FlightDesk Settings.
struct FlightWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Flights Overhead"
    static var description = IntentDescription("Live aircraft near you. Display options are set in FlightDesk Settings; these override them for this widget.")

    @Parameter(title: "Location", description: "City, airport or “lat, lon”. Leave blank to use the location set in FlightDesk.")
    var location: String?

    @Parameter(title: "Style", default: .app)
    var styleChoice: WidgetStyle

    @Parameter(title: "Radius", default: .app)
    var radiusChoice: WidgetRadius

    @Parameter(title: "LED Color", default: .app)
    var colorChoice: WidgetTheme

    @Parameter(title: "Units", default: .app)
    var unitsChoice: WidgetUnits

    /// App settings with this widget's overrides applied.
    func effective() -> (settings: AppSettings, radius: SearchRadius) {
        var s = AppSettings.load()
        s.display.style = styleChoice.resolve(s)
        s.display.theme = colorChoice.resolve(s)
        s.display.units = unitsChoice.resolve(s)
        return (s, radiusChoice.resolve(s))
    }
}

/// The ↻ button in the widget header. Running it makes WidgetKit reload the timeline.
struct RefreshFlightsIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Flights"
    static var isDiscoverable = false
    func perform() async throws -> some IntentResult { .result() }
}

struct FlightEntry: TimelineEntry {
    let date: Date
    let model: PanelModel
    let options: DisplayOptions
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> FlightEntry {
        FlightEntry(date: .now, model: .sample, options: DisplayOptions())
    }

    func snapshot(for config: FlightWidgetIntent, in context: Context) async -> FlightEntry {
        if context.isPreview { return FlightEntry(date: .now, model: .sample, options: config.effective().settings.display) }
        return await timeline(for: config, in: context).entries.first ?? placeholder(in: context)
    }

    func timeline(for config: FlightWidgetIntent, in context: Context) async -> Timeline<FlightEntry> {
        let now = Date()
        let (settings, radius) = config.effective()
        let opts = settings.display
        var model = PanelModel(radiusNM: radius.nm)

        var loc: (lat: Double, lon: Double, name: String)?
        if let text = config.location, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            loc = await FlightService.resolve(text)
            if loc == nil { model.status = "Can't find “\(text)”" }
        } else {
            loc = Shared.location
            if loc == nil { model.status = "Open FlightDesk or edit this widget to set a location" }
        }
        guard let loc else {
            return Timeline(entries: [FlightEntry(date: now, model: model, options: opts)], policy: .after(now + 900))
        }
        model.placeName = loc.name

        do {
            model.flights = try await FlightService.nearby(lat: loc.lat, lon: loc.lon,
                                                           radiusNM: radius.nm, includeGA: settings.includeGA)
            model.updated = now
            if model.flights.isEmpty { model.status = "Quiet skies — nothing within \(opts.radius(radius.nm))" }
        } catch {
            fdLog.error("Widget fetch failed: \(error.localizedDescription)")
            model.status = "No connection — retrying"
            return Timeline(entries: [FlightEntry(date: now, model: model, options: opts)], policy: .after(now + 120))
        }

        // A frame every 15 s for 5 minutes: aircraft are dead-reckoned forward from their live
        // position so distance/direction/altitude keep moving between fetches, and the featured
        // flight rotates every 30 s. A fresh fetch replaces this whenever WidgetKit reloads.
        let rotateCount = settings.rotate ? min(5, model.flights.count) : 1
        let step = 15.0, frames = 20
        var entries: [FlightEntry] = []
        for i in 0..<frames {
            let t = Double(i) * step
            var m = model
            m.flights = model.flights.map { $0.projected(by: t, observerLat: loc.lat, observerLon: loc.lon) }
            m.featuredIndex = rotateCount > 1 ? (i / 2) % rotateCount : 0
            entries.append(FlightEntry(date: now.addingTimeInterval(t), model: m, options: opts))
        }
        return Timeline(entries: entries, policy: .after(now + Double(frames) * step))
    }
}

struct FlightWidgetView: View {
    let entry: FlightEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var layout: PanelLayout {
        switch family {
        case .systemSmall: .small
        case .systemMedium: .medium
        case .systemExtraLarge: .extraLarge
        default: .large
        }
    }

    var body: some View {
        var o = entry.options
        // Clear / Tinted / Monochrome desktop widget styles: macOS renders the widget on its own
        // backing and tints accentable content, so drop our glow and texture.
        if renderingMode != .fullColor { o.glow = false; o.dotMatrix = false }
        // Clicking a flight opens its detail window in the app. Small widgets allow only one
        // tap target, so the whole widget links to the featured flight.
        let featuredURL = entry.model.featured.map { FlightLink.url(for: $0.id) }
        return PanelContent(model: entry.model, layout: layout, accessory: AnyView(refreshButton(o)))
            .environment(\.displayOptions, o)
            .environment(\.flightLinkStyle, family == .systemSmall ? .none : .link)
            .widgetURL(family == .systemSmall ? featuredURL : nil)
            .containerBackground(for: .widget) {
                // Standard: the system background, light or dark to match the Mac's appearance.
                if o.isStandard {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    PanelBackground().environment(\.displayOptions, o)
                }
            }
    }

    private func refreshButton(_ o: DisplayOptions) -> some View {
        Button(intent: RefreshFlightsIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(o.isStandard ? Color.secondary : o.theme.color.opacity(0.55))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh flights")
    }
}

struct FlightDeskWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Shared.widgetKind, intent: FlightWidgetIntent.self, provider: Provider()) {
            FlightWidgetView(entry: $0)
        }
        .configurationDisplayName("Flights Overhead")
        .description("Live aircraft near you, as an LED flight board or a clean system look.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

@main
struct FlightDeskWidgets: WidgetBundle {
    var body: some Widget { FlightDeskWidget() }
}
