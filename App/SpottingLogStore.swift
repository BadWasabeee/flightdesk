#if os(macOS)
import Cocoa
#else
import UIKit
#endif
import Combine

/// The app's spotting log: records every flight list the main app fetches (the radar, the panel
/// and the background pump) into a `SpottingLog`, kept in Application Support inside the sandbox
/// and never uploaded. Recording is O(n) per list on the main actor with no disk access; saves
/// are debounced and encoded and written on a background queue.
@MainActor
final class SpottingLogStore: ObservableObject {
    static let shared = SpottingLogStore()

    /// "Keep a spotting log" (on by default). Turning it off stops recording; the log is kept.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        }
    }
    /// The log as last published to views: at most every `publishInterval`, so a busy radar doesn't
    /// redraw the logbook (or copy the log) on every refresh.
    @Published private(set) var log = SpottingLog()
    /// Live aircraft whose type the log had never seen before this launch, for the radar's
    /// "First sighting" tag. Only filled once the log has history from earlier launches.
    @Published private(set) var firstTypeSightings: Set<String> = []
    @Published private(set) var isLoaded = false
    /// Bumped whenever `log` is published, so views can cache work derived from it.
    private(set) var revision = 0

    private static let enabledKey = "spottingLog.enabled"
    private static let saveDelay: Duration = .seconds(20)
    private static let publishInterval: TimeInterval = 10

    private let url: URL
    private var working = SpottingLog()
    /// Types known before each record, for `firstTypeSightings`.
    private var knownTypes: Set<String> = []
    private var hadHistory = false
    private var pending: [(flights: [Flight], at: Date)] = []
    private var lastPublish = Date.distantPast
    private var dirty = false
    private var saveTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private let io = DispatchQueue(label: "flightdesk.spotting-log", qos: .utility)
    private var terminateObserver: NSObjectProtocol?
    private var serverSyncTask: Task<Void, Never>?
    private var isSyncing = false

    init(url: URL = SpottingLog.defaultURL) {
        self.url = url
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        load()
        #if os(macOS)
        let flushOn = NSApplication.willTerminateNotification
        #else
        // iOS may end a suspended app without warning, so save whenever it leaves the screen.
        let flushOn = UIApplication.didEnterBackgroundNotification
        #endif
        terminateObserver = NotificationCenter.default.addObserver(forName: flushOn,
                                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushNow() }
        }
        serverSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await self?.syncFromServer()
                try? await Task.sleep(for: Self.serverSyncInterval)
            }
        }
    }

    private func load() {
        let url = url
        io.async { [weak self] in
            let loaded = SpottingLog.load(from: url)
            Task { @MainActor in self?.finishLoading(loaded) }
        }
    }

    private func finishLoading(_ loaded: SpottingLog) {
        working = loaded
        hadHistory = !loaded.isEmpty
        knownTypes = loaded.typeCodes
        isLoaded = true
        let queued = pending
        pending = []
        for batch in queued { apply(batch.flights, at: batch.at) }
        publish()
    }

    // MARK: Recording

    /// Records one fetched flight list. Cheap: a dictionary update per flight, no disk access.
    func record(_ flights: [Flight], at now: Date = Date()) {
        guard isEnabled, !flights.isEmpty else { return }
        guard isLoaded else {
            // Lists arriving in the moment before the file is read are replayed once it is.
            if pending.count < 20 { pending.append((flights, now)) }
            return
        }
        apply(flights, at: now)
    }

    private func apply(_ flights: [Flight], at now: Date) {
        let db = SpotterAlerts.shared.database
        let change = working.record(flights, at: now) { db?[$0]?.group }
        guard change.any else { return }
        var firsts: [String] = []
        for f in flights {
            let t = f.typeCode.uppercased()
            guard !t.isEmpty, !knownTypes.contains(t) else { continue }
            knownTypes.insert(t)
            if hadHistory, let hex = AircraftID.hex(f.id, allowNonICAO: false) { firsts.append(hex) }
        }
        if !firsts.isEmpty { firstTypeSightings.formUnion(firsts) }
        scheduleSave()
        schedulePublish()
    }

    /// Publishes now when the last publish is old enough, else once the interval has passed.
    private func schedulePublish() {
        let wait = Self.publishInterval - Date().timeIntervalSince(lastPublish)
        guard wait > 0 else { publish(); return }
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.publish()
        }
    }

    private func publish() {
        publishTask?.cancel()
        publishTask = nil
        lastPublish = Date()
        revision += 1
        log = working
    }

    // MARK: FlightDesk server

    private static let serverSyncInterval: Duration = .seconds(15 * 60)
    private static let serverCursorKey = "spottingLog.serverCursor"
    /// Pages of up to 1,000 airframes read per sync; the rest follow at the next one.
    private static let serverPagesPerSync = 10

    private struct StoredCursor: Codable {
        /// The server the cursor belongs to; another server starts from the beginning.
        var server: String
        var cursor: ServerSightingsPage.Cursor
    }

    /// Adds what the FlightDesk server's area poller has logged since the last sync (see
    /// `SpottingLog.absorb`), when the server and logbook syncing are on. Only downloads: the
    /// local log is never sent anywhere.
    func syncFromServer() async {
        let settings = ServerSettings.current
        guard isEnabled, isLoaded, !isSyncing, settings.isActive, settings.syncLogbook,
              let server = settings.baseURL?.absoluteString else { return }
        isSyncing = true
        defer { isSyncing = false }
        let defaults = UserDefaults.standard
        var cursor = defaults.data(forKey: Self.serverCursorKey)
            .flatMap { try? JSONDecoder().decode(StoredCursor.self, from: $0) }
            .flatMap { $0.server == server ? $0.cursor : nil }
        var imported: [LogEntry] = []
        for _ in 0..<Self.serverPagesPerSync {
            guard let page = await FlightDeskServer.shared.sightings(after: cursor) else { break }
            imported += page.sightings.compactMap(LogEntry.init(server:))
            if let last = page.sightings.last { cursor = .init(since: last.lastSeen, after: last.hex.lowercased()) }
            if page.next == nil { break }
        }
        if let cursor, let data = try? JSONEncoder().encode(StoredCursor(server: server, cursor: cursor)) {
            defaults.set(data, forKey: Self.serverCursorKey)
        }
        guard !imported.isEmpty, isEnabled else { return }
        let change = working.absorb(imported)
        guard change.any else { return }
        knownTypes.formUnion(imported.map(\.typeCode).filter { !$0.isEmpty })
        fdLog.info("Added \(imported.count) airframes from the FlightDesk server to the logbook")
        scheduleSave()
        schedulePublish()
    }

    // MARK: Clearing and export

    /// Deletes every entry, now and on disk.
    func clear() {
        working.removeAll()
        knownTypes = []
        hadHistory = false
        firstTypeSightings = []
        pending = []
        publish()
        saveTask?.cancel()
        saveTask = nil
        dirty = true
        save()
    }

    /// Writes `entries` as CSV to `destination` off the main thread.
    func exportCSV(_ entries: [LogEntry], to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            io.async {
                do {
                    try Data(SpottingLog.csv(entries).utf8).write(to: destination, options: .atomic)
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Saving

    /// Saves `saveDelay` after the first unsaved change (not pushed back by later ones, so a
    /// constantly refreshing radar still saves regularly).
    private func scheduleSave() {
        dirty = true
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            self.save()
        }
    }

    private func save() {
        guard dirty else { return }
        dirty = false
        let snapshot = working, url = url
        io.async {
            do { try snapshot.write(to: url) } catch { fdLog.error("Spotting log save failed: \(error.localizedDescription)") }
        }
    }

    /// At quit: waits for the pending save so the last few minutes aren't lost.
    private func flushNow() {
        saveTask?.cancel()
        saveTask = nil
        save()
        io.sync {}
    }
}
