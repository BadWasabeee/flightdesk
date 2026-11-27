import SwiftUI
import UserNotifications

/// Settings › Alerts: spotter notification rules, watchlist, quiet hours and the menu-bar readout.
struct SpotterSettingsView: View {
    @ObservedObject var store: LiveStore
    @ObservedObject private var alerts = SpotterAlerts.shared
    @State private var newKind: WatchItem.Kind = .registration
    @State private var newValue = ""
    @State private var showCategories = false

    private var s: Binding<SpotterSettings> { $alerts.settings }
    private var display: DisplayOptions { store.settings.display }

    var body: some View {
        Form {
            notificationsSection
            rulesSection
            interestingSection
            watchlistSection
            quietHoursSection
            menuBarSection
        }
        .formStyle(.grouped)
        .task { await alerts.refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await alerts.refreshAuthorization() }
        }
    }

    // MARK: Sections

    private var notificationsSection: some View {
        Section {
            LabeledContent("Permission") {
                switch alerts.authorization {
                case .authorized, .provisional:
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .denied:
                    HStack {
                        Text("Off").foregroundStyle(.secondary)
                        Button("Open System Settings…") { alerts.openNotificationSettings() }
                    }
                default:
                    Button("Allow Notifications") { Task { await alerts.requestAuthorizationIfNeeded() } }
                }
            }
            HStack {
                Button("Send Test Alert", systemImage: "bell.badge") { alerts.sendTest() }
                Spacer()
                if !alerts.lastTestResult.isEmpty {
                    Text(alerts.lastTestResult).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            if alerts.authorization == .denied {
                Text("Notifications are turned off for FlightDesk. Turn them on in System Settings › Notifications › FlightDesk.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("FlightDesk checks the sky around \(store.placeName.isEmpty ? "your location" : store.placeName) on the widget schedule, even with the panel hidden. Each aircraft alerts at most once every 2 hours per rule.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var rulesSection: some View {
        Section {
            Toggle("Emergency squawks (7500, 7600, 7700)", isOn: s.emergencies)
            Toggle("Wide-bodies and heavies", isOn: s.heavies)
            Toggle("Aircraft comes close", isOn: s.proximity)
            if alerts.settings.proximity {
                Picker("Within", selection: s.proximityNM) {
                    ForEach([1, 2, 3, 5, 10], id: \.self) { Text(display.withStandardStyle.radius($0)).tag($0) }
                }
            }
        } header: {
            Text("Rules")
        } footer: {
            Text("Rules cover every aircraft within your search radius, including private and general aviation.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var interestingSection: some View {
        Section {
            Toggle("Interesting aircraft", isOn: s.interesting)
            if alerts.settings.interesting {
                ForEach(PlaneAlertDB.groups, id: \.self) { g in
                    Toggle(isOn: member(\.interestingGroups, g)) {
                        HStack {
                            Text(PlaneAlertDB.groupTitle(g))
                            if let n = alerts.database?.groupCounts[g] { Text("\(n.formatted())").foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.leading, 12)
                }
                if let db = alerts.database {
                    DisclosureGroup("More categories (\(alerts.settings.interestingCategories.count) selected)", isExpanded: $showCategories) {
                        ForEach(db.categories, id: \.name) { c in
                            Toggle(isOn: member(\.interestingCategories, c.name)) {
                                HStack { Text(c.name); Spacer(); Text("\(c.count.formatted())").foregroundStyle(.secondary) }
                            }
                        }
                    }
                    .padding(.leading, 12)
                }
                HStack {
                    Text(alerts.databaseStatus.isEmpty ? "Loading list…" : alerts.databaseStatus)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Update Now") { alerts.ensureDatabase(force: true) }.controlSize(.small)
                }
            }
        } header: {
            Text("Interesting Aircraft")
        } footer: {
            Text("Military, government and notable aircraft from the community plane-alert-db (sdr-enthusiasts), downloaded from GitHub and refreshed weekly. Categories match in addition to the groups above.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var watchlistSection: some View {
        Section {
            Toggle("Alert for watchlist matches", isOn: s.watchlistEnabled)
            ForEach(alerts.settings.watchlist) { item in
                HStack {
                    Text(item.kind.title).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                    Text(item.value).font(.body.monospaced())
                    Spacer()
                    Button { alerts.settings.watchlist.removeAll { $0.id == item.id } } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(item.value)")
                }
            }
            HStack {
                Picker("", selection: $newKind) {
                    ForEach(WatchItem.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                TextField(newKind.placeholder, text: $newValue)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addWatchItem)
                Button("Add", action: addWatchItem).disabled(normalizedNew == nil || isDuplicate)
            }
            if !newValue.isEmpty, normalizedNew == nil {
                Text(validationHint).font(.caption).foregroundStyle(.red)
            } else if isDuplicate {
                Text("Already on your watchlist.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Watchlist")
        } footer: {
            Text("Registrations (N12345, G-EUPT), ICAO hex codes (a1b2c3), callsign prefixes (DAL matches every Delta flight) or ICAO type codes (A388, B748, C17).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var quietHoursSection: some View {
        Section("Quiet Hours") {
            Toggle("Silence alerts overnight", isOn: s.quietHours.enabled)
            if alerts.settings.quietHours.enabled {
                DatePicker("From", selection: time(\.start), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: time(\.end), displayedComponents: .hourAndMinute)
                Toggle("Always alert for emergencies", isOn: s.quietHours.allowEmergencies)
            }
        }
    }

    private var menuBarSection: some View {
        Section {
            Toggle("Show nearest airline flight in the menu bar", isOn: s.menuBarReadout)
            if alerts.settings.menuBarReadout {
                LabeledContent("Now") {
                    Text(MenuBarReadout.text(flights: alerts.lastFlights.isEmpty ? store.model.flights : alerts.lastFlights,
                                             known: store.model.flights, display: display) ?? "No airline flights nearby")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Menu Bar")
        } footer: {
            Text("Updates on the widget schedule, or every 15 seconds while the panel is open.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private var normalizedNew: String? { WatchItem.normalize(newValue, as: newKind) }
    private var isDuplicate: Bool {
        guard let v = normalizedNew else { return false }
        return alerts.settings.watchlist.contains { $0.kind == newKind && $0.value == v }
    }
    private var validationHint: String {
        switch newKind {
        case .hex: "An ICAO hex code is 6 characters, 0–9 and A–F."
        case .type: "An ICAO type code is 2–4 letters and digits, starting with a letter (e.g. B748)."
        case .callsign: "Use up to 8 letters and digits (e.g. DAL)."
        case .registration: "Use 2–10 letters, digits and dashes (e.g. G-EUPT)."
        }
    }

    private func addWatchItem() {
        guard let v = normalizedNew, !isDuplicate else { return }
        alerts.settings.watchlist.append(WatchItem(kind: newKind, value: v))
        newValue = ""
    }

    /// Binds a toggle to membership of `value` in one of the settings' string sets.
    private func member(_ path: WritableKeyPath<SpotterSettings, Set<String>>, _ value: String) -> Binding<Bool> {
        Binding(
            get: { alerts.settings[keyPath: path].contains(value) },
            set: { on in
                if on { alerts.settings[keyPath: path].insert(value) } else { alerts.settings[keyPath: path].remove(value) }
            })
    }

    /// Binds a DatePicker to minutes-after-midnight in quiet hours.
    private func time(_ path: WritableKeyPath<QuietHours, Int>) -> Binding<Date> {
        let cal = Calendar.current
        return Binding(
            get: {
                let m = alerts.settings.quietHours[keyPath: path]
                return cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let p = cal.dateComponents([.hour, .minute], from: d)
                alerts.settings.quietHours[keyPath: path] = (p.hour ?? 0) * 60 + (p.minute ?? 0)
            })
    }
}

private extension DisplayOptions {
    var withStandardStyle: DisplayOptions { var d = self; d.style = .standard; return d }
}
