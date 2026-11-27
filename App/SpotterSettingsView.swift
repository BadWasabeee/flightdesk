import SwiftUI
import UserNotifications

/// Settings › Alerts: notification permission, spotter rules, watchlist and quiet hours.
struct SpotterSettingsView: View {
    @ObservedObject var store: LiveStore
    @ObservedObject private var alerts = SpotterAlerts.shared
    @State private var newKind: WatchItem.Kind = .registration
    @State private var newValue = ""
    @State private var showCategories = false
    /// Set when Add/Return was tried with an invalid value; the hint turns red until the text changes.
    @State private var triedInvalid = false
    @FocusState private var entryFocused: Bool

    private var s: Binding<SpotterSettings> { $alerts.settings }
    private var display: DisplayOptions { store.settings.display }

    var body: some View {
        Form {
            notificationsSection
            rulesSection
            watchlistSection
            quietHoursSection
        }
        .formStyle(.grouped)
        .task { await alerts.refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await alerts.refreshAuthorization() }
        }
    }

    // MARK: Notifications

    private var notificationsSection: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: permission.symbol)
                    .font(.title2)
                    .foregroundStyle(permission.color)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.title)
                    Text(permissionDetail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                switch alerts.authorization {
                case .authorized, .provisional:
                    Button("Send Test") { alerts.sendTest() }
                        .help("Posts a sample alert for the nearest aircraft")
                case .denied:
                    Button("Open System Settings…") { alerts.openNotificationSettings() }
                default:
                    Button("Allow…") { Task { await alerts.requestAuthorizationIfNeeded() } }
                }
            }
            .accessibilityElement(children: .combine)
            if !alerts.lastTestResult.isEmpty {
                Label(alerts.lastTestResult, systemImage: "paperplane")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if alerts.authorization == .denied, !alerts.settings.activeRules.isEmpty {
                Label("Your rules are on, but macOS won’t show their alerts until notifications are allowed.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
        } header: {
            Text("Notifications")
        }
    }

    private var permission: (title: String, symbol: String, color: Color) {
        switch alerts.authorization {
        case .authorized, .provisional: ("Notifications are on", "bell.badge.fill", .green)
        case .denied: ("Notifications are off", "bell.slash.fill", .secondary)
        default: ("Notifications aren’t set up yet", "bell", .secondary)
        }
    }

    private var permissionDetail: String {
        switch alerts.authorization {
        case .authorized, .provisional:
            let place = store.placeName.isEmpty ? "your location" : store.placeName
            return "FlightDesk checks the sky around \(place) every \(SettingsMetrics.interval(store.settings.widgetRefreshSeconds)), even with no windows open."
        case .denied:
            return "Turn on notifications for FlightDesk in System Settings to get alerts."
        default:
            return "macOS asks once, the first time an alert rule is on."
        }
    }

    // MARK: Rules

    private var rulesSection: some View {
        Section {
            Toggle(isOn: s.emergencies) {
                Text("Emergency squawks")
                Text("7500 hijack, 7600 radio failure, 7700 general emergency")
            }
            Toggle(isOn: s.heavies) {
                Text("Wide-bodies")
                Text("A380, 747, 777, 787, A350 and other heavies")
            }
            Toggle(isOn: s.proximity) {
                Text("Close approaches")
                Text("Any aircraft passing within the distance you choose")
            }
            if alerts.settings.proximity {
                Picker("Distance", selection: s.proximityNM) {
                    ForEach([1, 2, 3, 5, 10], id: \.self) { Text(display.withStandardStyle.radius($0)).tag($0) }
                }
                .padding(.leading, SettingsMetrics.indent)
            }
            Toggle(isOn: s.interesting) {
                Text("Interesting aircraft")
                Text("Military, government and notable aircraft from the community plane-alert-db list")
            }
            if alerts.settings.interesting { interestingOptions }
            if alerts.mutedCount > 0 {
                HStack {
                    Label(alerts.mutedCount == 1 ? "1 aircraft muted for 24 hours" : "\(alerts.mutedCount) aircraft muted for 24 hours",
                          systemImage: "speaker.slash")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Unmute All") { alerts.unmuteAll() }
                }
            }
        } header: {
            Text("Alert Me About")
        } footer: {
            Text("Rules include private and general aviation. Each aircraft alerts at most once every 2 hours.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var interestingOptions: some View {
        ForEach(PlaneAlertDB.groups, id: \.self) { g in
            Toggle(isOn: member(\.interestingGroups, g)) {
                HStack {
                    Text(PlaneAlertDB.groupTitle(g))
                    Spacer()
                    if let n = alerts.database?.groupCounts[g] {
                        Text(n.formatted()).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .toggleStyle(.checkbox)
            .padding(.leading, SettingsMetrics.indent)
        }
        if let db = alerts.database {
            DisclosureGroup(isExpanded: $showCategories) {
                ForEach(db.categories, id: \.name) { c in
                    Toggle(isOn: member(\.interestingCategories, c.name)) {
                        HStack {
                            Text(c.name)
                            Spacer()
                            Text(c.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            } label: {
                let n = alerts.settings.interestingCategories.count
                Text(n == 0 ? "More categories" : "More categories · \(n) selected")
            }
            .padding(.leading, SettingsMetrics.indent)
        }
        HStack(spacing: 8) {
            if alerts.database == nil, alerts.databaseStatus.isEmpty || alerts.databaseStatus.hasSuffix("…") {
                ProgressView().controlSize(.small)
            }
            Text(alerts.databaseStatus.isEmpty ? "Loading the list…" : alerts.databaseStatus)
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Update Now") { alerts.ensureDatabase(force: true) }
                .help("Downloads the latest plane-alert-db list from GitHub (refreshed weekly)")
        }
        .padding(.leading, SettingsMetrics.indent)
    }

    // MARK: Watchlist

    private var watchlistSection: some View {
        Section {
            Toggle("Alert for watchlist matches", isOn: s.watchlistEnabled)
            if alerts.settings.watchlist.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "binoculars")
                        .font(.title2).foregroundStyle(.tertiary).frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your watchlist is empty").foregroundStyle(.secondary)
                        Text("Add a tail number, hex code, callsign or aircraft type below.")
                            .font(.callout).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            } else {
                ForEach(alerts.settings.watchlist) { item in watchRow(item) }
            }
            addRow
        } header: {
            Text("Watchlist")
        }
    }

    private func watchRow(_ item: WatchItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(.secondary).frame(width: 20)
                .accessibilityHidden(true)
            Text(item.value).font(.body.monospaced())
            Text(item.kind.title).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button { remove(item) } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove from watchlist")
            .accessibilityLabel("Remove \(item.value)")
        }
        .opacity(alerts.settings.watchlistEnabled ? 1 : 0.55)
        .contextMenu { Button("Remove \(item.value)") { remove(item) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.kind.title) \(item.value)")
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Match by", selection: $newKind) {
                    ForEach(WatchItem.Kind.allCases, id: \.self) { k in
                        Label(k.title, systemImage: k.symbol).tag(k)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Match by")
                TextField("Add to watchlist", text: $newValue, prompt: Text(verbatim: newKind.placeholder))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .focused($entryFocused)
                    .onSubmit(addWatchItem)
                Button("Add", action: addWatchItem)
                    .disabled(newValue.trimmingCharacters(in: .whitespaces).isEmpty || isDuplicate)
            }
            .onChange(of: newValue) { _, _ in triedInvalid = false }
            .onChange(of: newKind) { _, _ in triedInvalid = false }
            Group {
                if triedInvalid {
                    Label(newKind.validationHint, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                } else if !newValue.trimmingCharacters(in: .whitespaces).isEmpty, normalizedNew == nil {
                    Text(newKind.validationHint).foregroundStyle(.secondary)
                } else if isDuplicate {
                    Label("Already on your watchlist.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    Text(newKind.explanation).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    // MARK: Quiet hours

    private var quietHoursSection: some View {
        Section {
            Toggle(isOn: s.quietHours.enabled) {
                Text("Quiet hours")
                Text("Silence alerts overnight, on top of any Focus you use")
            }
            if alerts.settings.quietHours.enabled {
                DatePicker("From", selection: time(\.start), displayedComponents: .hourAndMinute)
                    .padding(.leading, SettingsMetrics.indent)
                DatePicker("Until", selection: time(\.end), displayedComponents: .hourAndMinute)
                    .padding(.leading, SettingsMetrics.indent)
                Toggle("Still alert for emergencies", isOn: s.quietHours.allowEmergencies)
                    .padding(.leading, SettingsMetrics.indent)
            }
        } header: {
            Text("Quiet Hours")
        }
    }

    // MARK: Helpers

    private var normalizedNew: String? { WatchItem.normalize(newValue, as: newKind) }
    private var isDuplicate: Bool {
        guard let v = normalizedNew else { return false }
        return alerts.settings.watchlist.contains { $0.kind == newKind && $0.value == v }
    }

    private func addWatchItem() {
        guard let v = normalizedNew else {
            if !newValue.trimmingCharacters(in: .whitespaces).isEmpty { triedInvalid = true; NSSound.beep() }
            return
        }
        guard !isDuplicate else { return }
        withAnimation(.snappy) { alerts.settings.watchlist.append(WatchItem(kind: newKind, value: v)) }
        newValue = ""
        entryFocused = true
    }

    private func remove(_ item: WatchItem) {
        withAnimation(.snappy) { alerts.settings.watchlist.removeAll { $0.id == item.id } }
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

extension DisplayOptions {
    /// The same options with the plain (non-LED) style, for text outside the board.
    var withStandardStyle: DisplayOptions { var d = self; d.style = .standard; return d }
}
