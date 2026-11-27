// The Radar tab: every aircraft in range, searchable and sortable, with situation and runway tags.

import SwiftUI

struct FlightListScreen: View {
    @ObservedObject var store: LiveStore
    @ObservedObject var radar: RadarModel
    @ObservedObject private var log = SpottingLogStore.shared
    @ObservedObject private var router = AppRouter.shared
    @Environment(\.displayOptions) private var o

    private var flights: [Flight] { FlightListFilter.apply(radar.flights, query: radar.query, sort: radar.sort) }
    private var hasLocation: Bool { !store.placeName.isEmpty || Shared.location != nil }

    var body: some View {
        let shown = flights
        List {
            if !shown.isEmpty {
                Section {
                    ForEach(shown) { f in
                        Button { router.showFlight(hex: f.id, snapshot: f) } label: {
                            FlightRow(f: f, phase: radar.runwayPhases[f.id],
                                      firstSighting: log.firstTypeSightings.contains(f.id))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(radar.selection == f.id ? Color.accentColor.opacity(0.12) : nil)
                        .contextMenu { menu(f) }
                    }
                } header: {
                    header(shown: shown.count)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $radar.query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Callsign, reg, type, airport")
        .refreshable {
            await radar.refresh()
            await store.refresh()
        }
        .overlay { emptyState(shown: shown.count) }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
    }

    private var title: String {
        store.placeName.isEmpty ? "FlightDesk" : store.placeName
    }

    // MARK: Header and toolbar

    private func header(shown: Int) -> some View {
        HStack {
            Text(summary(shown: shown)).monospacedDigit()
            Spacer()
            if let t = radar.updated {
                Text(t, style: .time).foregroundStyle(.tertiary)
            }
        }
        .font(.footnote)
        .textCase(nil)
    }

    private func summary(shown: Int) -> String {
        let total = radar.flights.count
        let radius = o.radius(store.settings.radius.nm)
        let count = shown == total ? "\(total) aircraft" : "\(shown) of \(total) aircraft"
        return radar.feed == .offline ? "\(count) · offline, positions estimated" : "\(count) within \(radius)"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort By", selection: $radar.sort) {
                    ForEach(FlightSort.allCases) { Text($0.title).tag($0) }
                }
                Picker("Radius", selection: $store.settings.radius) {
                    ForEach(SearchRadius.allCases, id: \.self) { Text(o.radius($0.nm)).tag($0) }
                }
                Toggle("Airlines Only", isOn: Binding(get: { !store.settings.includeGA },
                                                      set: { store.settings.includeGA = !$0 }))
            } label: {
                Label("Sort and Filter", systemImage: "line.3.horizontal.decrease")
            }
            .accessibilityLabel("Sort and filter, sorted by \(radar.sort.title)")
        }
    }

    @ViewBuilder private func menu(_ f: Flight) -> some View {
        Button("Show Details", systemImage: "info.circle") { router.showFlight(hex: f.id, snapshot: f) }
        Button("Copy Flight Number", systemImage: "doc.on.doc") { UIPasteboard.general.string = f.displayNumber }
        if !f.reg.isEmpty { Button("Copy Registration", systemImage: "doc.on.doc") { UIPasteboard.general.string = f.reg } }
    }

    // MARK: Empty states

    @ViewBuilder
    private func emptyState(shown: Int) -> some View {
        if !hasLocation {
            ContentUnavailableView {
                Label("Set Your Location", systemImage: "location.slash")
            } description: {
                Text(store.locationStatus.isEmpty ? "FlightDesk shows the aircraft flying around the place you choose." : store.locationStatus)
            } actions: {
                Button("Use Current Location") { store.requestCurrentLocation() }
                    .buttonStyle(.borderedProminent)
                Button("Choose a Place") { router.showSettings(.general) }
            }
        } else if shown == 0 && !radar.flights.isEmpty {
            ContentUnavailableView.search(text: radar.query)
        } else if shown == 0 {
            switch radar.feed {
            case .offline:
                ContentUnavailableView {
                    Label("Can’t Reach the Flight Feed", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("FlightDesk will keep trying.")
                } actions: {
                    Button("Try Again") { Task { await radar.refresh() } }
                }
            case .empty:
                ContentUnavailableView {
                    Label("Quiet Skies", systemImage: "airplane")
                } description: {
                    Text("No aircraft within \(o.radius(store.settings.radius.nm)) right now.")
                } actions: {
                    if let wider = SearchRadius.allCases.last, wider != store.settings.radius {
                        Button("Search Within \(o.radius(wider.nm))") { store.settings.radius = wider }
                    }
                    if !store.settings.includeGA {
                        Button("Include Private & GA") { store.settings.includeGA = true }
                    }
                }
            case .loading, .live, .noLocation:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Looking for aircraft…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}
