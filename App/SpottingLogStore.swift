import Cocoa
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

    init(url: URL = SpottingLog.defaultURL) {
        self.url = url
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        load()
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushNow() }
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
