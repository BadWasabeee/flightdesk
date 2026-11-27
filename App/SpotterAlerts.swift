import Cocoa
import UserNotifications

/// Spotter alerts: runs `SpotterEngine` on every flight list the app fetches, posts local notifications,
/// keeps the plane-alert-db cache fresh, and drives the optional menu-bar readout.
@MainActor
final class SpotterAlerts: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = SpotterAlerts()

    @Published var settings = SpotterSettings.decode(Shared.defaults.data(forKey: SpotterSettings.key)) {
        didSet {
            guard settings != oldValue else { return }
            Shared.defaults.set(try? JSONEncoder().encode(settings), forKey: SpotterSettings.key)
            if !settings.activeRules.isSubset(of: oldValue.activeRules) { Task { await requestAuthorizationIfNeeded() } }
            if settings.activeRules.contains(.interesting) { ensureDatabase() }
            onChange?()
        }
    }
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var database: PlaneAlertDB?
    @Published private(set) var databaseStatus = ""
    @Published private(set) var lastTestResult = ""
    /// Aircraft currently silenced with "Mute for 24 Hours".
    @Published private(set) var mutedCount = 0

    /// Called after settings change (the menu-bar readout listens).
    var onChange: (() -> Void)?
    /// Most recent flight list seen, nearest first.
    private(set) var lastFlights: [Flight] = []

    private var ledger: AlertLedger = Shared.defaults.data(forKey: AlertLedger.key)
        .flatMap { try? JSONDecoder().decode(AlertLedger.self, from: $0) } ?? AlertLedger()
    private var databaseTask: Task<Void, Never>?
    private var lastDownloadAttempt = Date.distantPast
    private var center: UNUserNotificationCenter { .current() }

    /// True when something needs flight data even while no window is visible.
    var needsBackgroundFlights: Bool {
        settings.menuBarReadout || !settings.activeRules.isEmpty
    }

    static let categoryID = "spotter.alert"
    private static let showAction = "spotter.show"
    private static let muteAction = "spotter.mute"

    /// Call from `applicationDidFinishLaunching` so clicks on notifications delivered while quit are handled.
    func start() {
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [UNNotificationAction(identifier: Self.showAction, title: "Show Details", options: [.foreground]),
                      UNNotificationAction(identifier: Self.muteAction, title: "Mute for 24 Hours", options: [])],
            intentIdentifiers: [], options: [])])
        mutedCount = ledger.mutedCount(now: Date())
        Task { await refreshAuthorization() }
        if settings.activeRules.contains(.interesting) { ensureDatabase() }
    }

    // MARK: Evaluation

    /// Runs every rule over `flights` and notifies about anything new.
    func process(_ flights: [Flight]) {
        lastFlights = flights
        guard !settings.activeRules.isEmpty else { return }
        if settings.activeRules.contains(.interesting) { ensureDatabase() }
        let now = Date()
        let candidates = SpotterEngine.applyQuietHours(
            SpotterEngine.evaluate(flights, settings: settings, db: database, squawk: \.squawk), settings.quietHours, at: now)
        guard !candidates.isEmpty else { return }
        Task {
            await refreshAuthorization()
            if authorization == .notDetermined { await requestAuthorizationIfNeeded() }
            guard authorization.canNotify else { return }       // don't burn dedupe slots while notifications are off
            ledger.prune(now: now)
            mutedCount = ledger.mutedCount(now: now)
            let fresh = ledger.admit(candidates, now: now)
            guard !fresh.isEmpty else { return }
            saveLedger()
            for alert in fresh { await post(alert) }
        }
    }

    private func saveLedger() {
        Shared.defaults.set(try? JSONEncoder().encode(ledger), forKey: AlertLedger.key)
    }

    private func post(_ alert: SpotterAlert, identifier: String? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.subtitle
        content.body = alert.body(display: AppSettings.load().display)
        content.sound = .default
        // `.timeSensitive` would need the time-sensitive notifications entitlement; `.active` is the default
        // and still sounds and shows a banner.
        content.interruptionLevel = .active
        // One stack per rule in Notification Center (emergencies, watchlist, military…).
        content.threadIdentifier = "spotter.\(alert.rule.rawValue)"
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["hex": alert.flight.id, "flight": (try? JSONEncoder().encode(alert.flight)) ?? Data()]
        let request = UNNotificationRequest(identifier: identifier ?? "spotter.\(alert.rule.rawValue).\(alert.flight.id)",
                                            content: content, trigger: nil)
        do { try await center.add(request) } catch { fdLog.error("Spotter notification failed: \(error.localizedDescription)") }
    }

    /// Posts a sample alert for the nearest aircraft (or a demo flight) so users can check delivery.
    func sendTest() {
        Task {
            await requestAuthorizationIfNeeded()
            guard authorization.canNotify else {
                lastTestResult = "Notifications are turned off for FlightDesk."
                return
            }
            let flight = lastFlights.first ?? PanelModel.sample.flights[0]
            await post(SpotterAlert(flight: flight, rule: .watchlist, label: "Test alert", entry: database?[flight.id]),
                       identifier: "spotter.test")
            lastTestResult = "Sent a test alert for \(flight.displayNumber)."
        }
    }

    // MARK: Muting

    /// Silences every rule for one aircraft for 24 hours and clears its delivered alerts.
    func mute(hex: String) {
        ledger.mute(hex: hex, now: Date())
        mutedCount = ledger.mutedCount(now: Date())
        saveLedger()
        Task {
            let ids = await center.deliveredNotifications()
                .filter { ($0.request.content.userInfo["hex"] as? String)?.lowercased() == hex.lowercased() }
                .map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func unmuteAll() {
        ledger.unmuteAll()
        mutedCount = 0
        saveLedger()
    }

    // MARK: Authorization

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    func requestAuthorizationIfNeeded() async {
        await refreshAuthorization()
        guard authorization == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await refreshAuthorization()
    }

    func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
            ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.open(url)
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show banners even while FlightDesk is frontmost (e.g. Settings open).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// Clicking an alert (or Show Details) opens that aircraft's detail window; Mute silences it for a day.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        // Only act on a well-formed aircraft address, and only trust a snapshot of that same aircraft.
        let hex = (info["hex"] as? String).flatMap { AircraftID.hex($0) }
        let snapshot = (info["flight"] as? Data)
            .flatMap { try? JSONDecoder().decode(Flight.self, from: $0) }
            .flatMap { $0.id.lowercased() == hex ? $0 : nil }
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let hex {
                    switch action {
                    case UNNotificationDefaultActionIdentifier, Self.showAction:
                        FlightDetail.show(hex: hex, snapshot: snapshot)
                    case Self.muteAction:
                        SpotterAlerts.shared.mute(hex: hex)
                    default: break
                    }
                }
                completionHandler()
            }
        }
    }

    // MARK: plane-alert-db

    private static let databaseURL = URL(string: "https://raw.githubusercontent.com/sdr-enthusiasts/plane-alert-db/main/plane-alert-db.csv")!
    private static let databaseMaxAge: TimeInterval = 7 * 86_400
    private var databaseFile: URL { Shared.containerURL.appendingPathComponent("plane-alert-db.csv") }

    /// Anonymous, cookie-less session with FlightDesk's User-Agent and request accounting: the
    /// download carries no location or identifiers. A longer overall timeout than the API session,
    /// as the list is a few megabytes.
    private static let downloadSession = Net.session(Net.configuration(request: 30, resource: 90))

    /// Loads the cached list, downloading it if missing or older than a week. Safe to call often.
    func ensureDatabase(force: Bool = false) {
        guard databaseTask == nil else { return }
        let file = databaseFile
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let stale = modified.map { Date().timeIntervalSince($0) > Self.databaseMaxAge } ?? true
        let canRetry = Date().timeIntervalSince(lastDownloadAttempt) > 3600
        guard database == nil || force || (stale && canRetry) else { return }

        databaseTask = Task {
            defer { databaseTask = nil }
            if database == nil, modified != nil, let db = await Self.parse(contentsOf: file) {
                setDatabase(db, updated: modified)
            }
            guard force || (stale && canRetry) else { return }
            lastDownloadAttempt = Date()
            if database == nil { databaseStatus = "Downloading the list…" }
            do {
                let (data, response) = try await Self.downloadSession.boundedData(from: Self.databaseURL, limit: ResponseLimit.csv)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                guard let db = await Task.detached(priority: .utility, operation: { PlaneAlertDB(csv: data) }).value,
                      db.entries.count > 100 else { throw URLError(.cannotParseResponse) }
                try data.write(to: file, options: .atomic)
                setDatabase(db, updated: Date())
            } catch {
                fdLog.error("plane-alert-db download failed: \(error.localizedDescription)")
                databaseStatus = database == nil ? "Couldn’t download the list. FlightDesk will try again later." : databaseStatus
            }
        }
    }

    private func setDatabase(_ db: PlaneAlertDB, updated: Date?) {
        database = db
        let when = updated.map { " · updated \($0.formatted(.relative(presentation: .named)))" } ?? ""
        databaseStatus = "\(db.entries.count.formatted()) aircraft\(when)"
    }

    private static func parse(contentsOf file: URL) async -> PlaneAlertDB? {
        await Task.detached(priority: .utility) {
            (try? Data(contentsOf: file)).flatMap(PlaneAlertDB.init(csv:))
        }.value
    }
}

extension UNAuthorizationStatus {
    var canNotify: Bool { self == .authorized || self == .provisional }
}

// MARK: - App wiring (status-item readout + data hooks)

extension AppDelegate {
    /// Connects spotter alerts and the menu-bar readout to the live data. Call once at launch, before `store.start()`.
    func installSpotterAlerts() {
        let alerts = SpotterAlerts.shared
        alerts.start()
        store.wantsBackgroundFlights = { SpotterAlerts.shared.needsBackgroundFlights }
        store.onFlights = { [weak self] flights in
            SpotterAlerts.shared.process(flights)
            self?.updateStatusReadout()
        }
        alerts.onChange = { [weak self] in self?.updateStatusReadout() }
        updateStatusReadout()
    }

    /// Shows the nearest airline flight next to the status icon when enabled; otherwise the plain icon.
    func updateStatusReadout() {
        guard let button = statusItem?.button else { return }
        let text = SpotterAlerts.shared.settings.menuBarReadout
            ? MenuBarReadout.text(flights: SpotterAlerts.shared.lastFlights, known: store.model.flights, display: store.settings.display)
            : nil
        if let text {
            statusItem.length = NSStatusItem.variableLength
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.title = " " + text
            button.setAccessibilityLabel("FlightDesk, nearest flight \(text)")
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            statusItem.length = NSStatusItem.squareLength
            button.setAccessibilityLabel("FlightDesk")
        }
    }
}
