import SwiftUI
import CoreLocation
#if os(macOS)
import ServiceManagement
#else
import UIKit
#endif

// MARK: - Tabs

enum SettingsTab: String, CaseIterable, Hashable {
    case general, widget, alerts, sources

    var title: String {
        switch self {
        case .general: "General"
        case .widget: "Widget"
        case .alerts: "Alerts"
        case .sources: "Sources"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .widget: "square.grid.2x2"
        case .alerts: "bell.badge"
        case .sources: "antenna.radiowaves.left.and.right"
        }
    }
}

extension SettingsTab {
    /// flightdesk://settings/<general|widget|alerts|sources> (also `receiver`, `data`, and the
    /// former `display`, now part of Widget).
    init?(url: URL) {
        guard url.scheme == FlightLink.scheme, url.host == "settings" else { return nil }
        let tab = url.lastPathComponent.lowercased()
        switch tab {
        case "", "/": self = .general
        case "receiver", "data": self = .sources
        case "display", "appearance": self = .widget
        default: self.init(rawValue: tab)
        }
    }
}

/// Shared layout constants and copy helpers for the Settings panes.
enum SettingsMetrics {
    /// The widest a pane grows in the main window, so its forms don't stretch.
    static let width: CGFloat = 600
    /// Leading inset for options that depend on the row above.
    static let indent: CGFloat = 18

    /// "15 seconds", "1 minute", "2 minutes".
    static func interval(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }
}

// MARK: - Location search (Settings › General and the welcome window)

/// Search field plus "Use Current Location", with progress and errors shown inline.
struct LocationSearch: View {
    @ObservedObject var store: LiveStore
    @State private var query = ""
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search", text: $query, prompt: Text("City, airport code or coordinates"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit(search)
                    .accessibilityLabel("Search for a location")
                Button("Set", action: search)
                    #if os(iOS)
                    .buttonStyle(.borderless)
                    #endif
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
            HStack(spacing: 8) {
                Button("Use Current Location", systemImage: "location") { store.requestCurrentLocation() }
                    #if os(iOS)
                    .buttonStyle(.borderless)
                    #endif
                Spacer(minLength: 0)
                if locationDenied {
                    #if os(macOS)
                    Button("Open Privacy Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                    }
                    #else
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    #endif
                }
            }
            if !store.locationStatus.isEmpty { statusLine }
        }
        .padding(.vertical, 2)
    }

    private var busy: Bool { store.locationStatus.hasSuffix("…") }

    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
            Text(store.locationStatus)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private var locationDenied: Bool {
        let s = LocationAccess.manager.authorizationStatus
        return s == .denied || s == .restricted
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !searching else { return }
        searching = true
        Task {
            if await store.setManualLocation(q) { query = "" }
            searching = false
        }
    }
}

/// Reads location authorization for display only (LiveStore owns the manager that asks).
@MainActor
enum LocationAccess {
    static let manager = CLLocationManager()
}

/// The current place with a location pin, or a "not set" hint.
struct CurrentPlace: View {
    @ObservedObject var store: LiveStore

    var body: some View {
        if store.placeName.isEmpty {
            Label("Not set", systemImage: "location.slash").foregroundStyle(.secondary)
        } else {
            Label(store.placeName, systemImage: "location.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - General

#if os(macOS)

struct GeneralSettings: View {
    @ObservedObject var store: LiveStore
    @ObservedObject private var alerts = SpotterAlerts.shared
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval

    var body: some View {
        Form {
            Section("Location") {
                LabeledContent("Current location") { CurrentPlace(store: store) }
                LocationSearch(store: store)
            }

            Section {
                Picker("Search radius", selection: $store.settings.radius) {
                    ForEach(SearchRadius.allCases, id: \.self) { r in
                        Text(String(localized: SearchRadius.caseDisplayRepresentations[r]!.title)).tag(r)
                    }
                }
                Picker("Units", selection: $store.settings.display.units) {
                    Text("ft · kt · nm").tag(UnitSystem.imperial)
                    Text("m · km/h · km").tag(UnitSystem.metric)
                }
                Toggle(isOn: $store.settings.includeGA) {
                    Text("Include private and general aviation")
                    Text("Light aircraft, helicopters and business jets")
                }
            } header: {
                Text("Flights")
            } footer: {
                Text("Each widget can override these in Edit Widget.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Menu Bar and Desktop") {
                Toggle(isOn: $alerts.settings.menuBarReadout) {
                    Text("Show nearest flight in the menu bar")
                    Text(menuBarDetail)
                }
                Toggle(isOn: $store.settings.showPanel) {
                    Text("Show live desktop panel")
                    Text("A floating board that refreshes every 15 seconds")
                }
                Toggle("Keep panel above other windows", isOn: $store.settings.keepOnTop)
                    .disabled(!store.settings.showPanel)
                    .padding(.leading, SettingsMetrics.indent)
            }

            SpottingLogSettingsSection()

            Section {
                Toggle("Open FlightDesk at login", isOn: $loginEnabled)
                    .onChange(of: loginEnabled) { _, on in setLogin(on) }
                if loginNeedsApproval {
                    HStack {
                        Label("Waiting for approval in Login Items.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    .font(.callout)
                }
            } header: {
                Text("System")
            } footer: {
                Text("At login FlightDesk starts quietly in the menu bar, so widgets and alerts stay up to date.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
        }
    }

    private var menuBarDetail: String {
        guard alerts.settings.menuBarReadout else { return "Shows the nearest airline flight and its distance next to the icon" }
        let flights = alerts.lastFlights.isEmpty ? store.model.flights : alerts.lastFlights
        let now = MenuBarReadout.text(flights: flights, known: store.model.flights, display: store.settings.display)
        return now.map { "Now: \($0)" } ?? "No airline flights nearby right now"
    }

    private func setLogin(_ on: Bool) {
        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
        catch { fdLog.error("Login item change failed: \(error.localizedDescription)") }
        let status = SMAppService.mainApp.status
        loginNeedsApproval = status == .requiresApproval
        if (status == .enabled) != on, !loginNeedsApproval { loginEnabled = status == .enabled }
    }
}
#endif

// MARK: - Display

/// Preview, look and content of the widget and desktop panel (part of the Widget tab).
struct WidgetAppearanceSections: View {
    @ObservedObject var store: LiveStore

    var body: some View {
        Group {
            Section {
                preview
                    .padding(.vertical, 4)
                    .animation(.easeInOut(duration: 0.25), value: store.settings.display)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Preview of the widget and desktop panel")
            } header: {
                Text("Preview")
            }

            Section("Look") {
                Picker("Style", selection: $store.settings.display.style) {
                    ForEach(BoardStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("LED color") {
                    HStack(spacing: 10) {
                        ForEach(LEDTheme.allCases, id: \.self) { t in swatch(t) }
                    }
                }
                .disabled(store.settings.display.isStandard)
                Toggle("LED glow", isOn: $store.settings.display.glow)
                    .disabled(store.settings.display.isStandard)
                Toggle("Dot-matrix texture", isOn: $store.settings.display.dotMatrix)
                    .disabled(store.settings.display.isStandard)
            }

            Section {
                Toggle("Show location header", isOn: $store.settings.display.showHeader)
                Toggle("Show flight list", isOn: $store.settings.display.showList)
                Toggle("Show city names", isOn: $store.settings.display.showCities)
                Toggle("Show airline logos", isOn: $store.settings.display.showLogos)
                Toggle(isOn: $store.settings.rotate) {
                    Text("Rotate featured flight")
                    Text("Cycles through the five nearest flights")
                }
            } header: {
                Text("Content")
            } footer: {
                #if os(macOS)
                Text("Applies to the desktop panel and every widget. To style one widget differently, right-click it and choose **Edit “Flights Overhead”**.")
                    .font(.caption).foregroundStyle(.secondary)
                #else
                Text("Applies to every widget. To style one widget differently, touch and hold it and choose **Edit Widget**.")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
            }
        }
    }

    @ViewBuilder private var preview: some View {
        let m = store.model.flights.isEmpty ? PanelModel.sample : store.model
        #if os(macOS)
        PanelContent(model: m, layout: .panel)
            .environment(\.displayOptions, store.settings.display)
            .frame(width: 460)
            .modifier(PanelChrome(options: store.settings.display))
            .frame(maxWidth: .infinity)
        #else
        // A medium Home Screen widget, at its size on most iPhones.
        PanelContent(model: m, layout: .medium)
            .environment(\.displayOptions, store.settings.display)
            .frame(width: 338, height: 158)
            .background(store.settings.display.isStandard ? AnyView(Color(uiColor: .secondarySystemGroupedBackground))
                        : AnyView(PanelBackground().environment(\.displayOptions, store.settings.display)))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .frame(maxWidth: .infinity)
        #endif
    }

    private func swatch(_ t: LEDTheme) -> some View {
        let name = String(localized: LEDTheme.caseDisplayRepresentations[t]!.title)
        let selected = store.settings.display.theme == t
        return Button { store.settings.display.theme = t } label: {
            Circle().fill(t.color).frame(width: 20, height: 20)
                .overlay(Circle().stroke(Color.primary, lineWidth: selected ? 2 : 0).padding(-3))
                .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Widget

#if os(macOS)

struct WidgetSettings: View {
    @ObservedObject var store: LiveStore

    var body: some View {
        Form {
            Section {
                step(1, "Right-click an empty spot on the desktop and choose **Edit Widgets…**")
                step(2, "Search for **FlightDesk**.")
                step(3, "Drag a size onto your desktop, then click **Done**.")
            } header: {
                Text("Add the Widget")
            } footer: {
                Text("Every option below can also be set per widget: right-click it and choose **Edit “Flights Overhead”**.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            WidgetAppearanceSections(store: store)

            Section {
                Picker("Update widgets every", selection: $store.settings.widgetRefreshSeconds) {
                    ForEach([15, 30, 60, 120, 300], id: \.self) { Text(SettingsMetrics.interval($0)).tag($0) }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Refresh widgets now")
                        if let d = store.lastWidgetReload {
                            Text("Last requested \(d.formatted(date: .omitted, time: .standard))")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { store.reloadWidgets() }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("While FlightDesk is running it checks the sky at this interval and updates widgets when aircraft arrive, leave or change course. Between updates, widgets move each aircraft along its heading every 15 seconds. macOS may delay updates — click ↻ on a widget to refresh it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.callout.bold()).monospacedDigit()
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
                .accessibilityHidden(true)
            Text(text)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Step \(n): ") + Text(text))
    }
}
#endif

// MARK: - Sources

struct SourcesSettings: View {
    @ObservedObject var store: LiveStore
    @State private var receiver = ReceiverSettings.current
    @State private var testingReceiver = false
    @State private var receiverTest: ReceiverFeed.TestResult?
    @State private var served: ServedSource?
    @State private var serverActive = ServerSettings.current.isActive

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $receiver.enabled) {
                    Text("Use my ADS-B receiver")
                    Text("dump1090-fa, readsb, tar1090, PiAware or ultrafeeder on your network")
                }
                if receiver.enabled {
                    TextField("Address", text: $receiver.url, prompt: Text(verbatim: "http://raspberrypi.local/tar1090"))
                        .autocorrectionDisabled()
                        .onSubmit(testReceiver)
                        .help("The address of the receiver’s map page")
                    connectionRow
                    Toggle(isOn: $receiver.useAsOnlySource) {
                        Text("Only use my receiver")
                        Text("Positions never come from the internet. Routes and aircraft details still come from adsbdb.")
                    }
                }
            } header: {
                Text("Your Receiver")
            }
            .onChange(of: receiver) { old, new in
                new.save()
                if old.url != new.url { receiverTest = nil } else { refreshData() }
            }

            FlightDeskServerSection(onChange: refreshData)

            Section {
                LabeledContent("Positions", value: positionsSummary)
                if let served {
                    LabeledContent("Last update") {
                        Text("\(served.source.title) · \(Text(served.time, style: .relative)) ago")
                            .monospacedDigit()
                    }
                }
                ForEach(DataCredits.all.dropFirst()) { c in
                    LabeledContent(c.role) { Link(c.name, destination: c.url) }
                }
            } header: {
                Text("Data Sources")
            } footer: {
                Text("Live feeds only ever receive a rounded position (about 1 km). These are free community services — consider contributing a feeder.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            RequestUsageSection()
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                served = await FeedHealth.shared.lastServed
                serverActive = ServerSettings.current.isActive
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var connectionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Test Connection", action: testReceiver)
                    .disabled(!receiver.hasURL || testingReceiver)
                if testingReceiver {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let r = receiverTest, !testingReceiver {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.message).foregroundStyle(.primary)
                        if let detail = r.detail {
                            Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.ok ? .green : .orange)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 2)
    }

    private var positionsSummary: String {
        let internet = serverActive ? "your FlightDesk server, then adsb.fi and adsb.lol" : "adsb.fi and adsb.lol"
        guard receiver.isActive else { return serverActive ? "Your FlightDesk server, then adsb.fi and adsb.lol" : "adsb.fi, then adsb.lol" }
        return receiver.useAsOnlySource ? "Your receiver only" : "Your receiver, then \(internet)"
    }

    private func testReceiver() {
        guard receiver.hasURL, !testingReceiver else { return }
        let base = receiver.url
        let observer = Shared.location.map { GeoPoint(lat: $0.lat, lon: $0.lon) }
        let radius = store.settings.radius.nm
        let label = store.settings.display.withStandardStyle.radius(radius)
        testingReceiver = true
        Task {
            let result = await ReceiverFeed.test(base, observer: observer, radiusNM: radius, radiusLabel: label)
            guard base == receiver.url else { testingReceiver = false; return }   // edited meanwhile
            receiverTest = result
            testingReceiver = false
            if result.ok { refreshData() }
        }
    }

    /// Fetches again so a source change shows up right away in the panel and widgets.
    private func refreshData() {
        Task {
            await store.refresh()
            store.reloadWidgets()
        }
    }
}

// MARK: - FlightDesk server

/// Settings › Sources › FlightDesk Server: the address (app-group defaults), the token (Keychain,
/// shared with the widget), a connection test and whether to sync the logbook.
struct FlightDeskServerSection: View {
    /// Called after a change that should refetch (the panel and widgets pick up the new source).
    var onChange: () -> Void

    static let guideURL = URL(string: "https://github.com/BadWasabeee/flightdesk/blob/main/Server/README.md")!

    @State private var settings = ServerSettings.current
    @State private var token = ""
    @State private var tokenLoaded = false
    @State private var tokenError: String?
    @State private var testing = false
    @State private var test: FlightDeskServer.TestResult?
    @State private var skippedUntil: Date?
    @State private var problem: String?

    private var addressProblem: ServerAddress.Problem? {
        guard !settings.url.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if case .failure(let p) = ServerAddress.check(settings.url) { return p }
        return nil
    }

    var body: some View {
        Section {
            Toggle(isOn: $settings.enabled) {
                Text("Use my FlightDesk server")
                Text("Your self-hosted cache and flight history. If it can’t be reached, FlightDesk uses the public services as usual.")
            }
            if settings.enabled {
                TextField("Server URL", text: $settings.url, prompt: Text(verbatim: "https://flightdesk.example.com"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    #endif
                    .onSubmit(runTest)
                if let p = addressProblem {
                    Text(p.message).font(.caption).foregroundStyle(.orange)
                }
                SecureField("Token", text: $token, prompt: Text("Bearer token from the server"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit(runTest)
                if let tokenError {
                    Text(tokenError).font(.caption).foregroundStyle(.orange)
                }
                testRow
                Toggle(isOn: $settings.syncLogbook) {
                    Text("Add the server’s sightings to the logbook")
                    Text("Aircraft the server saw in its area while \(DeviceName.this) wasn’t looking. Downloaded only; your logbook isn’t uploaded.")
                }
                if let skippedUntil, let problem {
                    Label("Not responding (\(problem)). Using the public services until \(skippedUntil.formatted(date: .omitted, time: .shortened)).",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("FlightDesk Server")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("The token is kept in the Keychain on \(DeviceName.this) and sent only to this server.")
                Link("How to set up a FlightDesk server", destination: Self.guideURL)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: loadToken)
        .onChange(of: settings) { old, new in
            new.save()
            if old.url != new.url { test = nil }
            Task {
                await FlightDeskServer.shared.reset()
                if old.enabled != new.enabled || old.url != new.url { onChange() }
            }
        }
        .task(id: token) {
            // Saves shortly after typing stops, so each keystroke isn't a Keychain write.
            guard tokenLoaded else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            saveToken()
        }
        .task {
            while !Task.isCancelled {
                skippedUntil = await FlightDeskServer.shared.skippedUntil
                problem = await FlightDeskServer.shared.lastProblem
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var testRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Test Connection", action: runTest)
                    .disabled(settings.url.trimmingCharacters(in: .whitespaces).isEmpty || testing)
                if testing {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let r = test, !testing {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.message).foregroundStyle(.primary)
                        if let detail = r.detail {
                            Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.ok ? .green : .orange)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 2)
    }

    private func loadToken() {
        guard !tokenLoaded else { return }
        token = KeychainSecretStore.serverToken.read() ?? ""
        // Let the load itself settle before `.task(id: token)` treats changes as edits.
        DispatchQueue.main.async { tokenLoaded = true }
    }

    private func saveToken() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != (KeychainSecretStore.serverToken.read() ?? "") else { return }
        do {
            try KeychainSecretStore.serverToken.write(value.isEmpty ? nil : value)
            tokenError = nil
            test = nil
            Task {
                await FlightDeskServer.shared.reset()
                onChange()
            }
        } catch {
            tokenError = error.localizedDescription
        }
    }

    private func runTest() {
        guard !testing else { return }
        saveToken()
        let url = settings.url, token = token
        testing = true
        Task {
            let result = await FlightDeskServer.test(url: url, token: token)
            guard url == settings.url else { testing = false; return }   // edited meanwhile
            test = result
            testing = false
            if result.ok {
                await FlightDeskServer.shared.reset()
                onChange()
            }
        }
    }
}

// MARK: - Credits

/// Data sources FlightDesk relies on, shown in Settings › Sources and the About panel.
struct DataCredits: Identifiable {
    let role: String
    let name: String
    let url: URL
    var id: String { role }

    static let all: [DataCredits] = [
        DataCredits(role: "Live positions", name: "adsb.fi and adsb.lol", url: URL(string: "https://adsb.fi")!),
        DataCredits(role: "Routes and aircraft", name: "adsbdb", url: URL(string: "https://www.adsbdb.com")!),
        DataCredits(role: "Flight tracks", name: "OpenSky Network", url: URL(string: "https://opensky-network.org")!),
        DataCredits(role: "Airport weather", name: "aviationweather.gov", url: URL(string: "https://aviationweather.gov")!),
        DataCredits(role: "Aircraft photos", name: "Planespotters.net", url: URL(string: "https://www.planespotters.net")!),
        DataCredits(role: "Interesting aircraft", name: "plane-alert-db",
                    url: URL(string: "https://github.com/sdr-enthusiasts/plane-alert-db")!),
        DataCredits(role: "Airline logos", name: "Soaring Symbols and others",
                    url: URL(string: "https://github.com/soaring-symbols/soaring-symbols")!),
        DataCredits(role: "Airports", name: "OurAirports", url: URL(string: "https://ourairports.com")!),
    ]
}

/// Today's requests per service, against each service's free daily allowance.
struct RequestUsageSection: View {
    @State private var counts: [ApiService: Int] = [:]
    @State private var paused: [ApiService: Date] = [:]

    private var services: [ApiService] {
        ApiService.allCases.filter { $0 != .other && (counts[$0] ?? 0) > 0 || $0.dailyLimit != nil }
    }

    var body: some View {
        Section {
            ForEach(services, id: \.self) { service in
                LabeledContent(service.title) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(usage(service)).monospacedDigit()
                        if let until = paused[service] {
                            Text("Resting until \(until.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Requests Today")
        } footer: {
            Text("Results are cached and shared with the widget. FlightDesk stops using a service before it reaches its daily allowance.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            while !Task.isCancelled {
                counts = ApiBudget.counts
                paused = Dictionary(uniqueKeysWithValues: ApiService.allCases.compactMap { s in ApiBudget.pausedUntil(s).map { (s, $0) } })
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func usage(_ service: ApiService) -> String {
        let n = (counts[service] ?? 0).formatted()
        return service.dailyLimit.map { "\(n) of \($0.formatted())" } ?? n
    }
}
