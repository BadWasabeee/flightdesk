import SwiftUI
import ServiceManagement

enum SettingsTab: Hashable { case general, display, widget }

struct SettingsView: View {
    @ObservedObject var store: LiveStore
    @State private var tab: SettingsTab
    private let onTabChange: (SettingsTab) -> Void

    init(store: LiveStore, tab: SettingsTab, onTabChange: @escaping (SettingsTab) -> Void = { _ in }) {
        self.store = store
        _tab = State(initialValue: tab)
        self.onTabChange = onTabChange
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            DisplaySettings(store: store)
                .tabItem { Label("Display", systemImage: "paintpalette") }.tag(SettingsTab.display)
            WidgetSettings(store: store)
                .tabItem { Label("Widget", systemImage: "square.grid.2x2") }.tag(SettingsTab.widget)
        }
        .frame(width: 560, height: 640)
        .onChange(of: tab) { _, t in onTabChange(t) }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @ObservedObject var store: LiveStore
    @State private var query = ""
    @State private var searching = false
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Location") {
                LabeledContent("Current") {
                    Text(store.placeName.isEmpty ? "Not set" : store.placeName)
                        .foregroundStyle(store.placeName.isEmpty ? .secondary : .primary)
                }
                HStack {
                    TextField("City, airport or lat, lon", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(search)
                    Button("Set", action: search).disabled(query.isEmpty || searching)
                }
                Button("Use This Mac’s Location", systemImage: "location") { store.requestCurrentLocation() }
                if !store.locationStatus.isEmpty {
                    Text(store.locationStatus).font(.callout).foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Search radius", selection: $store.settings.radius) {
                    ForEach(SearchRadius.allCases, id: \.self) { r in
                        Text(String(localized: SearchRadius.caseDisplayRepresentations[r]!.title)).tag(r)
                    }
                }
                Toggle("Include private & general aviation", isOn: $store.settings.includeGA)
            } header: {
                Text("Flights")
            } footer: {
                Text("Applies to all widgets and the desktop panel. A widget can override this in Edit Widget.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Data") {
                LabeledContent("Positions", value: "adsb.lol · live ADS-B / MLAT")
                LabeledContent("Routes & aircraft", value: "adsbdb · verified against live position")
            }

            Section("System") {
                Toggle("Launch FlightDesk at login", isOn: $loginEnabled)
                    .onChange(of: loginEnabled) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { loginEnabled = SMAppService.mainApp.status == .enabled }
                    }
            }
        }
        .formStyle(.grouped)
    }

    private func search() {
        let q = query
        guard !q.isEmpty else { return }
        searching = true
        Task {
            if await store.setManualLocation(q) { query = "" }
            searching = false
        }
    }
}

// MARK: - Display

struct DisplaySettings: View {
    @ObservedObject var store: LiveStore

    var body: some View {
        Form {
            Section("Preview") {
                let m = store.model.flights.isEmpty ? PanelModel.sample : store.model
                PanelContent(model: m, layout: .panel)
                    .environment(\.displayOptions, store.settings.display)
                    .frame(width: 460)
                    .modifier(PanelChrome(options: store.settings.display))
                    .frame(maxWidth: .infinity)
                    .animation(.easeInOut(duration: 0.25), value: store.settings.display)
            }

            Section("Look") {
                Picker("Style", selection: $store.settings.display.style) {
                    ForEach(BoardStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("LED color") {
                    HStack(spacing: 10) {
                        ForEach(LEDTheme.allCases, id: \.self) { t in
                            Button { store.settings.display.theme = t } label: {
                                Circle().fill(t.color).frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(Color.primary, lineWidth: store.settings.display.theme == t ? 2 : 0).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: LEDTheme.caseDisplayRepresentations[t]!.title))
                            .accessibilityLabel(String(localized: LEDTheme.caseDisplayRepresentations[t]!.title))
                        }
                    }
                }
                .disabled(store.settings.display.isStandard)
                Toggle("LED glow", isOn: $store.settings.display.glow)
                    .disabled(store.settings.display.isStandard)
                Toggle("Dot-matrix texture", isOn: $store.settings.display.dotMatrix)
                    .disabled(store.settings.display.isStandard)
            }

            Section {
                Picker("Units", selection: $store.settings.display.units) {
                    Text("ft · kt · nm").tag(UnitSystem.imperial)
                    Text("m · km/h · km").tag(UnitSystem.metric)
                }
                .pickerStyle(.segmented)
                Toggle("Show city names", isOn: $store.settings.display.showCities)
                Toggle("Show airline logos", isOn: $store.settings.display.showLogos)
                Toggle("Show flight list", isOn: $store.settings.display.showList)
                Toggle("Show header", isOn: $store.settings.display.showHeader)
                Toggle("Rotate featured flight", isOn: $store.settings.rotate)
            } header: {
                Text("Content")
            } footer: {
                Text("These apply to all widgets and the desktop panel. Changes reach the widgets within a few seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show live desktop panel", isOn: $store.settings.showPanel)
                Toggle("Keep panel above other windows", isOn: $store.settings.keepOnTop)
                    .disabled(!store.settings.showPanel)
            } header: {
                Text("Live Desktop Panel")
            } footer: {
                Text("An optional floating panel that updates every 15 seconds, alongside the native widget.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Widget

struct WidgetSettings: View {
    @ObservedObject var store: LiveStore

    var body: some View {
        Form {
            Section("Add the widget to your desktop") {
                step(1, "Right-click an empty spot on the desktop and choose **Edit Widgets…**")
                step(2, "Search for **FlightDesk**.")
                step(3, "Drag the Small, Medium, Large or Extra Large size onto your desktop.")
                step(4, "Everything in FlightDesk Settings applies to your widgets. To give one widget its own location, radius, color or units, right-click it › **Edit “Flights Overhead”**.")
            }

            Section {
                Picker("Fetch new data every", selection: $store.settings.widgetRefreshSeconds) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
                HStack {
                    Button("Refresh Widgets Now", systemImage: "arrow.clockwise") { store.reloadWidgets() }
                    Spacer()
                    if let d = store.lastWidgetReload {
                        Text("Last requested \(d.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("While FlightDesk is running it fetches fresh positions for the widgets on this schedule. Between fetches the widget moves each aircraft along its live heading and speed every 15 seconds. macOS may still throttle updates. Click ↻ on a widget to refresh it immediately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.callout.bold()).frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text)
        }
    }
}
