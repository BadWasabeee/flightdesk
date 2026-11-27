// The Settings tab. General settings are the root; Widgets, Alerts and Sources are pushed pages
// built from the Mac's Settings sections (App/SettingsView.swift, App/SpotterSettingsView.swift).

import SwiftUI
import WidgetKit

struct SettingsScreen: View {
    @ObservedObject var store: LiveStore
    @ObservedObject private var alerts = SpotterAlerts.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Current location") { CurrentPlace(store: store) }
                LocationSearch(store: store)
            } header: {
                Text("Location")
            } footer: {
                Text(store.followsDevice
                     ? "Follows your iPhone’s location whenever you open FlightDesk. Search for a place to keep it fixed."
                     : "A fixed place. Use Current Location to follow your iPhone instead.")
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
                    Text("Private and general aviation")
                    Text("Light aircraft, helicopters and business jets")
                }
            } header: {
                Text("Flights")
            } footer: {
                Text("Each widget can override these in Edit Widget.")
            }

            Section {
                NavigationLink(value: SettingsTab.widget) {
                    row("Widgets", "square.grid.2x2", .blue, detail: store.settings.display.style.title)
                }
                NavigationLink(value: SettingsTab.alerts) {
                    row("Alerts", "bell.badge.fill", .red, detail: alerts.settings.activeRules.isEmpty ? "Off" : "\(alerts.settings.activeRules.count) on")
                }
                NavigationLink(value: SettingsTab.sources) {
                    row("Sources and Usage", "antenna.radiowaves.left.and.right", .green, detail: nil)
                }
            }

            SpottingLogSettingsSection()

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Link(destination: URL(string: "https://github.com/BadWasabeee/flightdesk")!) {
                    Label("FlightDesk on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: SettingsTab.self) { tab in
            switch tab {
            case .widget: WidgetSettingsPage(store: store)
            case .alerts:
                SpotterSettingsView(store: store)
                    .navigationTitle("Alerts")
            case .sources:
                SourcesSettings(store: store)
                    .navigationTitle("Sources and Usage")
            case .general: EmptyView()
            }
        }
    }

    /// A Settings-style row: a coloured symbol tile, the title and a value on the right.
    private func row(_ title: String, _ symbol: String, _ tint: Color, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.gradient))
                .accessibilityHidden(true)
            Text(title)
            Spacer()
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
    }
}

/// Settings › Widgets: how to add them, the shared look, and an honest note about refreshes.
private struct WidgetSettingsPage: View {
    @ObservedObject var store: LiveStore

    var body: some View {
        Form {
            Section {
                step(1, "Touch and hold an empty spot on the Home Screen or Lock Screen until the apps jiggle, then tap **Edit**.")
                step(2, "Tap **Add Widget** and search for **FlightDesk**.")
                step(3, "Choose **Flights Overhead** for the Home Screen, or **Nearest Flight** for the Lock Screen.")
            } header: {
                Text("Add a Widget")
            }

            WidgetAppearanceSections(store: store)

            Section {
                Button("Refresh Widgets Now", systemImage: "arrow.clockwise") { store.reloadWidgets() }
                if let d = store.lastWidgetReload {
                    LabeledContent("Last requested", value: d.formatted(date: .omitted, time: .standard))
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Widgets refresh when you leave FlightDesk and every few minutes after that, as often as iOS allows. Between refreshes they move each aircraft along its heading.")
            }
        }
        .navigationTitle("Widgets")
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.callout.bold()).monospacedDigit()
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
                .accessibilityHidden(true)
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }
}
