import SwiftUI
import UniformTypeIdentifiers

/// The Logbook's view state, shared by its sidebar list and content pane.
@MainActor
final class LogbookModel: ObservableObject {
    @Published var selection: LogEntry.ID?
    @Published var filter = LogFilter()
    @Published var sort: LogSort {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: Self.sortKey) }
    }
    @Published var exportError: String?

    private static let sortKey = "logbook.sort"
    /// The last filtered list, reused while the log, filter, sort and day are unchanged (the list
    /// and the content pane both ask for it on every redraw).
    private var cache: (revision: Int, filter: LogFilter, sort: LogSort, day: Date, hasDB: Bool, list: [LogEntry])?
    private var statsCache: (revision: Int, day: Date, stats: LogStats)?

    init() {
        sort = UserDefaults.standard.string(forKey: Self.sortKey).flatMap(LogSort.init(rawValue:)) ?? .lastSeen
    }

    func visible(in store: SpottingLogStore, db: PlaneAlertDB?, now: Date = Date()) -> [LogEntry] {
        let day = Calendar.current.startOfDay(for: now)
        if let c = cache, c.revision == store.revision, c.filter == filter, c.sort == sort, c.day == day,
           c.hasDB == (db != nil) { return c.list }
        let list = store.log.entries(matching: filter, sort: sort, now: now) { db?[$0]?.group }
        cache = (store.revision, filter, sort, day, db != nil, list)
        return list
    }

    func stats(of store: SpottingLogStore, now: Date = Date()) -> LogStats {
        let day = Calendar.current.startOfDay(for: now)
        if let c = statsCache, c.revision == store.revision, c.day == day { return c.stats }
        let s = store.log.stats(now: now)
        statsCache = (store.revision, day, s)
        return s
    }

    #if os(macOS)
    /// Asks where to save `entries` as CSV, then writes them off the main thread.
    func export(_ entries: [LogEntry]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.exportFileName
        panel.message = "The logbook is exported from this Mac only."
        let write: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try await SpottingLogStore.shared.exportCSV(entries, to: url) } catch {
                    self?.exportError = error.localizedDescription
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: write) } else { panel.begin(completionHandler: write) }
    }
    #endif

    /// The suggested CSV file name for an export made today.
    nonisolated static var exportFileName: String { "FlightDesk Logbook \(Date().formatted(.iso8601.year().month().day())).csv" }
}

// MARK: - Sidebar

#if os(macOS)

/// The Logbook's sidebar: every logged airframe, searchable, filterable and sortable.
struct LogbookList: View {
    @ObservedObject var model: LogbookModel
    @ObservedObject private var store = SpottingLogStore.shared
    @ObservedObject private var alerts = SpotterAlerts.shared

    var body: some View {
        let entries = model.visible(in: store, db: alerts.database)
        List(selection: $model.selection) {
            if !store.log.isEmpty {
                Section {
                    ForEach(entries) { LogbookRow(entry: $0, sort: model.sort).tag($0.id) }
                } header: {
                    header(shown: entries.count)
                }
            }
        }
        .contextMenu(forSelectionType: LogEntry.ID.self) { ids in
            if let id = ids.first, let e = store.log[id] {
                if !e.registration.isEmpty { Button("Copy Registration") { copy(e.registration) } }
                Button("Copy ICAO Hex") { copy(e.hex.uppercased()) }
            }
        }
        .searchable(text: $model.filter.query, placement: .sidebar, prompt: "Reg, type, operator, callsign")
        .overlay { emptyState(shown: entries.count) }
        .accessibilityLabel("Logbook")
    }

    private func header(shown: Int) -> some View {
        HStack(spacing: 8) {
            Text(shown == store.log.count ? "\(shown) aircraft" : "\(shown) of \(store.log.count) aircraft")
                .monospacedDigit()
            Spacer()
            Menu {
                Picker("Period", selection: $model.filter.period) {
                    ForEach(LogPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Wide-Bodies Only", isOn: $model.filter.wideBodiesOnly)
                Toggle("Military Only", isOn: $model.filter.militaryOnly)
            } label: {
                Text(filterTitle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Filter: \(filterTitle)")
            .help("Filter the logbook")
            Menu {
                Picker("Sort By", selection: $model.sort) {
                    ForEach(LogSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text("Sort: \(model.sort.title)")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Sort by \(model.sort.title)")
            .help("Sort the logbook")
        }
    }

    private var filterTitle: String {
        let f = model.filter
        return [f.period.title, f.wideBodiesOnly ? "Wide" : nil, f.militaryOnly ? "Military" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func emptyState(shown: Int) -> some View {
        if store.log.isEmpty {
            ContentUnavailableView {
                Label(store.isLoaded ? "No Aircraft Logged Yet" : "Loading…", systemImage: "book.closed")
            } description: {
                Text(store.isEnabled
                     ? "Every aircraft FlightDesk sees near you is added here."
                     : "The spotting log is off. Turn it on in Settings › General.")
            }
        } else if shown == 0 {
            if !model.filter.query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: model.filter.query)
            } else {
                ContentUnavailableView {
                    Label("Nothing Matches", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(model.filter.militaryOnly && alerts.database == nil
                         ? "Military aircraft are recognised with the plane-alert-db list, which loads when the Interesting Aircraft alert is on."
                         : "No logged aircraft match these filters.")
                } actions: {
                    Button("Show All") { model.filter = LogFilter() }
                }
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
#endif

struct LogbookRow: View {
    let entry: LogEntry
    let sort: LogSort
    @Environment(\.displayOptions) private var o

    var body: some View {
        HStack(spacing: 10) {
            LogBadge(entry: entry, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName).font(.headline).lineLimit(1)
                Text([entry.typeCode, entry.operatorName].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(LogFormat.when(sort == .firstSeen ? entry.firstSeen : entry.lastSeen))
                Text([entry.sightings > 1 ? "\(entry.sightings)×" : nil, LogFormat.distance(entry.closestNM, o)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([entry.displayName, entry.typeCode, entry.operatorName].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityValue("Seen \(entry.sightings) \(entry.sightings == 1 ? "time" : "times"), last \(LogFormat.when(entry.lastSeen)), closest \(LogFormat.distance(entry.closestNM, o))")
    }
}

/// The airline logo when it's already cached (never downloaded for the log), else the class symbol.
struct LogBadge: View {
    let entry: LogEntry
    let size: CGFloat
    @Environment(\.displayOptions) private var o

    var body: some View {
        Group {
            if o.showLogos, let key = AirlineLogos.Key(icao: entry.airlineICAO, iata: entry.airlineIATA),
               let logo = LogoStore.logo(for: key.id) {
                Image(platformImage: logo.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                let kind = AircraftClass(typeCode: entry.typeCode)
                Circle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: kind.symbol)
                            .font(.system(size: size * 0.42 * min(1.15, kind.iconScale + 0.15), weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(kind == .rotorcraft ? 0 : -45))
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Content

#if os(macOS)
/// The Logbook's content: totals across the top, then the selected aircraft or an overview.
struct LogbookContent: View {
    @ObservedObject var radar: RadarModel
    @ObservedObject var model: LogbookModel
    @ObservedObject private var store = SpottingLogStore.shared

    var body: some View {
        let stats = model.stats(of: store)
        VStack(spacing: 0) {
            LogStatsHeader(stats: stats) { type in model.filter.query = type }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            Group {
                if let id = model.selection, let entry = store.log[id] {
                    LogEntryDetail(entry: entry, live: radar.flights.first { $0.id.caseInsensitiveCompare(id) == .orderedSame })
                        .id(id)
                } else {
                    LogOverview(store: store)
                }
            }
            .frame(maxWidth: SettingsMetrics.width)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Couldn’t Export the Logbook", isPresented: Binding(get: { model.exportError != nil },
                                                                   set: { if !$0 { model.exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.exportError ?? "")
        }
    }
}
#endif

struct LogStatsHeader: View {
    let stats: LogStats
    /// How many rare-type chips fit on one line (8 in the Mac window, fewer on a phone).
    var rareLimit = 8
    let showType: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                tile("Aircraft", stats.aircraft)
                tile("Types", stats.types)
                tile("Airlines", stats.airlines)
                tile("Today", stats.today)
            }
            if !stats.rarestTypes.isEmpty {
                HStack(spacing: 6) {
                    Text("Rarest").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(stats.rarestTypes.prefix(rareLimit), id: \.self) { type in
                        Button(type) { showType(type) }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold).monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                            .help("Seen on only one aircraft · show it")
                    }
                    if stats.rarestTypes.count > rareLimit {
                        Text("+\(stats.rarestTypes.count - rareLimit)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Rarest types, seen only once")
            }
        }
    }

    private func tile(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 1) {
            Text(value.formatted()).font(.title2.weight(.bold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Shown when nothing is selected: what the log is and where it lives.
struct LogOverview: View {
    @ObservedObject var store: SpottingLogStore

    var body: some View {
        Form {
            Section {
                Label("Select an aircraft in the list to see when and how close you saw it.", systemImage: "book")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $store.isEnabled) {
                    Text("Keep a spotting log")
                    Text("Records every aircraft FlightDesk sees near you")
                }
            } footer: {
                Text(LogFormat.privacyNote).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

struct LogEntryDetail: View {
    let entry: LogEntry
    /// The aircraft as it is now, when it's in range.
    let live: Flight?
    @ObservedObject private var alerts = SpotterAlerts.shared
    @Environment(\.displayOptions) private var o

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
            Form {
                if let live {
                    Section {
                        Label("In range now · \(o.distance(live.distance)) \(live.direction) · \(o.altitude(live.altitude))",
                              systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Section("Aircraft") {
                    fact("Type", entry.typeCode.isEmpty ? "—" : entry.typeCode)
                    fact("Registration", entry.registration.isEmpty ? "—" : entry.registration)
                    fact("Operator", entry.operatorName.isEmpty ? "—" : entry.operatorName)
                    if let e = alerts.database?[entry.hex] {
                        if !e.type.isEmpty { fact("Model", e.type) }
                        fact("Category", [PlaneAlertDB.groupTitle(e.group), e.category].filter { !$0.isEmpty }.joined(separator: " · "))
                    }
                    fact("ICAO Hex", entry.hex.uppercased())
                }
                Section("Sightings") {
                    fact("First Seen", LogFormat.full(entry.firstSeen))
                    fact("Last Seen", LogFormat.full(entry.lastSeen))
                    fact("Sightings", entry.sightings.formatted())
                }
                Section("Closest Pass") {
                    fact("Distance", LogFormat.distance(entry.closestNM, o))
                    fact("When", LogFormat.full(entry.closestAt))
                    fact("Highest Altitude", o.altitude(entry.maxAltitude))
                }
                if !entry.callsigns.isEmpty {
                    Section("Callsigns") {
                        Text(entry.callsigns.reversed().joined(separator: ", ")).monospaced().textSelection(.enabled)
                    }
                }
                if !entry.routes.isEmpty {
                    Section("Routes") {
                        Text(entry.routes.reversed().map { $0.replacingOccurrences(of: "-", with: " → ") }.joined(separator: "\n"))
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            if let live {
                Divider()
                Button { showOnRadar(live) } label: {
                    Text("Show on Radar").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Show this aircraft’s live detail")
                .padding(12)
            }
        }
    }

    /// Through the main window's in-window presenter (never a new window).
    private func showOnRadar(_ f: Flight) {
        #if os(macOS)
        withAnimation(MainWindowController.motion) {
            if let presenter = FlightDetail.presenter { presenter(f.id, f) }
        }
        #else
        FlightDetail.show(hex: f.id, snapshot: f)
        #endif
    }

    private var header: some View {
        HStack(spacing: 12) {
            LogBadge(entry: entry, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayOperator)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(entry.displayName)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }
}

// MARK: - Settings

/// Settings › General: the spotting-log switch and Clear Log, with an in-window confirmation.
struct SpottingLogSettingsSection: View {
    @ObservedObject private var store = SpottingLogStore.shared
    @State private var confirmingClear = false

    var body: some View {
        Section {
            Toggle(isOn: $store.isEnabled) {
                Text("Keep a spotting log")
                Text(store.log.isEmpty ? "Records every aircraft FlightDesk sees near you"
                     : "\(store.log.count.formatted()) aircraft logged")
            }
            HStack {
                Spacer()
                Button("Clear Log…", role: .destructive) { confirmingClear = true }
                    .disabled(store.log.isEmpty)
            }
            .confirmationDialog("Clear the spotting log?", isPresented: $confirmingClear) {
                Button("Clear Log", role: .destructive) { store.clear() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes all \(store.log.count.formatted()) aircraft from the logbook. It can’t be undone.")
            }
        } header: {
            Text("Logbook")
        } footer: {
            Text(LogFormat.privacyNote).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Formatting

enum LogFormat {
    static let privacyNote = "The logbook is stored only on \(DeviceName.this) and is never uploaded. It uses only the flight data FlightDesk already fetches."

    /// "14:05" today, "Nov 3" this year, else "Nov 3, 2024".
    static func when(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return d.formatted(date: .omitted, time: .shortened) }
        if calendar.isDate(d, equalTo: now, toGranularity: .year) { return d.formatted(.dateTime.month(.abbreviated).day()) }
        return d.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func full(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

    static func distance(_ nm: Double, _ o: DisplayOptions) -> String { nm < 100_000 ? o.distance(nm) : "—" }
}
