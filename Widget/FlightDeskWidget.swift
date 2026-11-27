// Native macOS desktop widget (WidgetKit) with per-widget configuration via "Edit Widget".

import WidgetKit
import SwiftUI
import AppIntents

enum WidgetRadius: String, AppEnum {
    case app, nm5 = "5", nm10 = "10", nm25 = "25", nm50 = "50", nm100 = "100"
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Radius"
    static let caseDisplayRepresentations: [WidgetRadius: DisplayRepresentation] = [
        .app: "Same as FlightDesk Settings", .nm5: "5 nm (9 km)", .nm10: "10 nm (19 km)",
        .nm25: "25 nm (46 km)", .nm50: "50 nm (93 km)", .nm100: "100 nm (185 km)",
    ]
    func resolve(_ s: AppSettings) -> SearchRadius { self == .app ? s.radius : SearchRadius(rawValue: rawValue) ?? s.radius }
}

enum WidgetTheme: String, AppEnum {
    case app, amber, green, red, blue, cyan, white
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "LED Color"
    static let caseDisplayRepresentations: [WidgetTheme: DisplayRepresentation] = [
        .app: "Same as FlightDesk Settings", .amber: "Amber", .green: "Green", .red: "Red",
        .blue: "Blue", .cyan: "Cyan", .white: "White",
    ]
    func resolve(_ s: AppSettings) -> LEDTheme { LEDTheme(rawValue: rawValue) ?? s.display.theme }
}

enum WidgetStyle: String, AppEnum {
    case app, led, standard
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Style"
    static let caseDisplayRepresentations: [WidgetStyle: DisplayRepresentation] = [
        .app: "Same as FlightDesk Settings", .led: "LED Board", .standard: "Standard",
    ]
    func resolve(_ s: AppSettings) -> BoardStyle { BoardStyle(rawValue: rawValue) ?? s.display.style }
}

enum WidgetUnits: String, AppEnum {
    case app, imperial, metric
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Units"
    static let caseDisplayRepresentations: [WidgetUnits: DisplayRepresentation] = [
        .app: "Same as FlightDesk Settings", .imperial: "Aviation (ft, kt, nm)", .metric: "Metric (m, km/h, km)",
    ]
    func resolve(_ s: AppSettings) -> UnitSystem { UnitSystem(rawValue: rawValue) ?? s.display.units }
}

/// Per-widget overrides shown in "Edit Widget". Everything else comes from FlightDesk Settings.
/// An on/off option that can also follow the app's setting.
enum WidgetToggle: String, AppEnum {
    case app, on, off
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Option"
    static let caseDisplayRepresentations: [WidgetToggle: DisplayRepresentation] = [
        .app: "Same as FlightDesk Settings", .on: "On", .off: "Off",
    ]
    func resolve(_ app: Bool) -> Bool {
        switch self { case .app: app; case .on: true; case .off: false }
    }
}

struct FlightWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Flights Overhead"
    static let description = IntentDescription("Choose what this widget shows. Options left on “Same as FlightDesk Settings” follow the app.")

    @Parameter(title: "Location",
               description: "A city, airport code or coordinates (“39.7, -104.9”). Leave empty to use the location set in FlightDesk.")
    var location: String?

    @Parameter(title: "Style", description: "LED Board glows like a departures board. Standard follows Light and Dark Mode.",
               default: .app)
    var styleChoice: WidgetStyle

    @Parameter(title: "LED Color", description: "The color of the LED Board style.", default: .app)
    var colorChoice: WidgetTheme

    @Parameter(title: "Radius", description: "How far from the location to look for aircraft.", default: .app)
    var radiusChoice: WidgetRadius

    @Parameter(title: "Units", default: .app)
    var unitsChoice: WidgetUnits

    @Parameter(title: "Private & GA", description: "Include light aircraft, helicopters and business jets.", default: .app)
    var includeGAChoice: WidgetToggle

    @Parameter(title: "Flight List", description: "The list of other nearby flights (Large and Extra Large).", default: .app)
    var showListChoice: WidgetToggle

    @Parameter(title: "City Names", description: "City names under the airport codes.", default: .app)
    var showCitiesChoice: WidgetToggle

    @Parameter(title: "Airline Logos", default: .app)
    var showLogosChoice: WidgetToggle

    @Parameter(title: "Header", description: "Place, aircraft count and update time.", default: .app)
    var showHeaderChoice: WidgetToggle

    @Parameter(title: "LED Glow", default: .app)
    var glowChoice: WidgetToggle

    @Parameter(title: "Dot-Matrix Texture", default: .app)
    var dotMatrixChoice: WidgetToggle

    static var parameterSummary: some ParameterSummary {
        // LED Color means nothing to the Standard style, so don't offer it there.
        When(\.$styleChoice, .equalTo, WidgetStyle.standard) {
            Summary {
                \.$location
                \.$styleChoice
                \.$radiusChoice
                \.$unitsChoice
                \.$includeGAChoice
                \.$showListChoice
                \.$showCitiesChoice
                \.$showLogosChoice
                \.$showHeaderChoice
            }
        } otherwise: {
            Summary {
                \.$location
                \.$styleChoice
                \.$colorChoice
                \.$glowChoice
                \.$dotMatrixChoice
                \.$radiusChoice
                \.$unitsChoice
                \.$includeGAChoice
                \.$showListChoice
                \.$showCitiesChoice
                \.$showLogosChoice
                \.$showHeaderChoice
            }
        }
    }

    /// App settings with this widget's overrides applied.
    func effective() -> (settings: AppSettings, radius: SearchRadius) {
        var s = AppSettings.load()
        s.display.style = styleChoice.resolve(s)
        s.display.theme = colorChoice.resolve(s)
        s.display.units = unitsChoice.resolve(s)
        s.includeGA = includeGAChoice.resolve(s.includeGA)
        s.display.showList = showListChoice.resolve(s.display.showList)
        s.display.showCities = showCitiesChoice.resolve(s.display.showCities)
        s.display.showLogos = showLogosChoice.resolve(s.display.showLogos)
        s.display.showHeader = showHeaderChoice.resolve(s.display.showHeader)
        s.display.glow = glowChoice.resolve(s.display.glow)
        s.display.dotMatrix = dotMatrixChoice.resolve(s.display.dotMatrix)
        return (s, radiusChoice.resolve(s))
    }
}

/// The ↻ button in the widget header. Running it makes WidgetKit reload the timeline.
struct RefreshFlightsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Flights"
    static let isDiscoverable = false
    func perform() async throws -> some IntentResult { .result() }
}

struct FlightEntry: TimelineEntry {
    let date: Date
    let model: PanelModel
    let options: DisplayOptions
}

struct Provider: AppIntentTimelineProvider {
    /// The gallery and first-render placeholder: a full sky, drawn in the user's chosen style.
    func placeholder(in context: Context) -> FlightEntry {
        FlightEntry(date: .now, model: .gallery, options: AppSettings.load().display)
    }

    func snapshot(for config: FlightWidgetIntent, in context: Context) async -> FlightEntry {
        if context.isPreview { return FlightEntry(date: .now, model: .gallery, options: config.effective().settings.display) }
        return await timeline(for: config, in: context).entries.first ?? placeholder(in: context)
    }

    func timeline(for config: FlightWidgetIntent, in context: Context) async -> Timeline<FlightEntry> {
        let now = Date()
        let (settings, radius) = config.effective()
        let opts = settings.display
        var model = PanelModel(radiusNM: radius.nm)

        // Status strings read "Title — Detail"; `PanelNotice` turns them into a designed state.
        var loc: (lat: Double, lon: Double, name: String)?
        if let text = config.location?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            loc = await FlightService.resolve(text)
            if loc == nil { model.status = "Can't find “\(text)” — Edit the widget and try a city, airport code or coordinates" }
        } else {
            loc = Shared.location
            if loc == nil { model.status = "No location set — Choose one in FlightDesk or with Edit Widget" }
        }
        guard let loc else {
            return Timeline(entries: [FlightEntry(date: now, model: model, options: opts)], policy: .after(now + 900))
        }
        model.placeName = loc.name
        // Tell the app which area this widget shows, so it can reload widgets when it changes.
        WidgetDemand.record(WidgetArea(lat: loc.lat, lon: loc.lon, radiusNM: radius.nm, includeGA: settings.includeGA))

        do {
            model.flights = try await FlightService.nearby(lat: loc.lat, lon: loc.lon,
                                                           radiusNM: radius.nm, includeGA: settings.includeGA)
            model.updated = now
            if model.flights.isEmpty { model.status = "Quiet skies — Nothing within \(opts.radius(radius.nm)) right now" }
        } catch {
            fdLog.error("Widget fetch failed: \(error.localizedDescription)")
            model.status = "Can’t reach flight data — Retrying in a couple of minutes"
            return Timeline(entries: [FlightEntry(date: now, model: model, options: opts)], policy: .after(now + 120))
        }

        // A frame every 15 s for 5 minutes: aircraft are dead-reckoned forward from their live
        // position so distance/direction/altitude keep moving between fetches, and the featured
        // flight rotates every 30 s. A fresh fetch replaces this whenever WidgetKit reloads.
        let rotateCount = settings.rotate ? min(5, model.flights.count) : 1
        let step = 15.0, frames = 20
        var entries: [FlightEntry] = []
        // Runway phase of the featured flight only, per frame (it moves along final); the runway
        // table is only read when a featured flight is low enough (see `listPhase`).
        var phases: [String: RunwayPhase] = [:]
        for i in 0..<frames {
            let t = Double(i) * step
            var m = model
            m.flights = model.flights.map { $0.projected(by: t, observerLat: loc.lat, observerLon: loc.lon) }
            m.featuredIndex = rotateCount > 1 ? (i / 2) % rotateCount : 0
            if let f = m.featured {
                phases[f.id] = RunwayPhase.listed(ApproachAnalyzer.listPhase(of: f), previous: phases[f.id], flight: f)
                m.runwayPhases = phases[f.id].map { [f.id: $0] } ?? [:]
            }
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

    /// Where a click on the widget background goes. Small widgets allow only this one target,
    /// so it opens the featured flight; without a location it opens FlightDesk's location setting.
    private var widgetURL: URL? {
        if let f = entry.model.featured { return family == .systemSmall ? FlightLink.url(for: f.id) : nil }
        if entry.model.placeName.isEmpty { return URL(string: "\(FlightLink.scheme)://settings/general") }
        return nil
    }

    var body: some View {
        var o = entry.options
        // Clear / Tinted desktop styles and the dimmed (vibrant) state behind windows: macOS draws
        // the widget on its own backing and tints accentable content, so drop glow and texture.
        if renderingMode != .fullColor { o.glow = false; o.dotMatrix = false }
        return PanelContent(model: entry.model, layout: layout, accessory: AnyView(refreshButton))
            .environment(\.displayOptions, o)
            .environment(\.flightLinkStyle, family == .systemSmall ? .none : .link)
            .widgetURL(widgetURL)
            .containerBackground(for: .widget) {
                // Standard: the system widget background, light or dark to match the Mac's appearance.
                if o.isStandard {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    PanelBackground().environment(\.displayOptions, o)
                }
            }
    }

    private var refreshButton: some View {
        Button(intent: RefreshFlightsIntent()) { RefreshGlyph() }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh flights")
            .help("Refresh flights")
    }
}

struct FlightDeskWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Shared.widgetKind, intent: FlightWidgetIntent.self, provider: Provider()) {
            FlightWidgetView(entry: $0)
        }
        .configurationDisplayName("Flights Overhead")
        .description("The aircraft flying near you right now, on a glowing LED board or in a clean system style.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        // The board draws its own 14–16 pt margins so the LED texture and the layout grid line up.
        .contentMarginsDisabled()
    }
}

@main
struct FlightDeskWidgets: WidgetBundle {
    var body: some Widget { FlightDeskWidget() }
}
