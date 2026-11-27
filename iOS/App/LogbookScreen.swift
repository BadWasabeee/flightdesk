// The Logbook tab: every aircraft FlightDesk has seen, with totals, filters and CSV export. Rows,
// stats and the entry detail are the Mac logbook's views (App/LogbookView.swift).

import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct LogbookScreen: View {
    @ObservedObject var radar: RadarModel
    @StateObject private var model = LogbookModel()
    @ObservedObject private var store = SpottingLogStore.shared
    @ObservedObject private var alerts = SpotterAlerts.shared

    var body: some View {
        let entries = model.visible(in: store, db: alerts.database)
        List {
            if !store.log.isEmpty {
                Section {
                    LogStatsHeader(stats: model.stats(of: store), rareLimit: 4) { type in model.filter.query = type }
                        .padding(.vertical, 4)
                }
                Section {
                    ForEach(entries) { e in
                        NavigationLink(value: e.id) { LogbookRow(entry: e, sort: model.sort) }
                    }
                } header: {
                    Text(entries.count == store.log.count ? "\(entries.count) aircraft" : "\(entries.count) of \(store.log.count) aircraft")
                        .monospacedDigit()
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $model.filter.query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Reg, type, operator, callsign")
        .overlay { emptyState(shown: entries.count) }
        .navigationTitle("Logbook")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: String.self) { id in
            if let entry = store.log[id] {
                LogEntryDetail(entry: entry, live: radar.flights.first { $0.id.caseInsensitiveCompare(id) == .orderedSame })
                    .navigationTitle(entry.displayName)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                filterMenu
                ShareLink(item: LogbookCSV(entries: entries), preview: SharePreview(LogbookModel.exportFileName)) {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(entries.isEmpty)
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Period", selection: $model.filter.period) {
                ForEach(LogPeriod.allCases) { Text($0.title).tag($0) }
            }
            Picker("Sort By", selection: $model.sort) {
                ForEach(LogSort.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Wide-Bodies Only", isOn: $model.filter.wideBodiesOnly)
            Toggle("Military Only", isOn: $model.filter.militaryOnly)
        } label: {
            Label("Filter", systemImage: !(model.filter.period != .all || model.filter.wideBodiesOnly || model.filter.militaryOnly)
                  ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
    }

    @ViewBuilder
    private func emptyState(shown: Int) -> some View {
        if store.log.isEmpty {
            ContentUnavailableView {
                Label(store.isLoaded ? "No Aircraft Logged Yet" : "Loading…", systemImage: "book.closed")
            } description: {
                Text(store.isEnabled
                     ? "Every aircraft FlightDesk sees near you is added here."
                     : "The spotting log is off. Turn it on in Settings.")
            }
        } else if shown == 0 {
            if !model.filter.query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: model.filter.query)
            } else {
                ContentUnavailableView {
                    Label("Nothing Matches", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No logged aircraft match these filters.")
                } actions: {
                    Button("Show All") { model.filter = LogFilter() }
                }
            }
        }
    }
}

/// The visible logbook entries as a CSV file for the share sheet (written when shared).
struct LogbookCSV: Transferable {
    let entries: [LogEntry]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { csv in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(LogbookModel.exportFileName)
            try Data(SpottingLog.csv(csv.entries).utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
