// The iPhone app: a full-screen radar map with a sheet holding the flight list, logbook and Settings.

import SwiftUI
import WidgetKit

@main
struct FlightDeskApp: App {
    @StateObject private var store: LiveStore
    @StateObject private var radar: RadarModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = LiveStore()
        let radar = RadarModel(store: store)
        _store = StateObject(wrappedValue: store)
        _radar = StateObject(wrappedValue: radar)
        AppRouter.shared.attach(radar)
        Self.connect(store: store, radar: radar)
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, radar: radar)
                .onOpenURL { AppRouter.shared.open($0) }
                #if DEBUG
                .task { await DebugLaunch.run(store: store, radar: radar) }
                #endif
        }
        .onChange(of: scenePhase, initial: true) { _, phase in apply(phase) }
    }

    /// Live polling only while FlightDesk is on screen; widgets get a fresh timeline as it leaves.
    private func apply(_ phase: ScenePhase) {
        switch phase {
        case .active, .inactive:
            // Inactive is still on screen (a system alert, Control Center pulled down): keep it live.
            guard store.isPaused || !radar.isActive else { return }
            store.isPaused = false
            radar.setActive(true)
            store.refreshDeviceLocationIfFollowing()
            Task { await store.refresh() }
        case .background:
            store.isPaused = true
            radar.setActive(false)
            store.reloadWidgets()
        @unknown default:
            break
        }
    }

    /// The same wiring the Mac's AppDelegate does: alerts, the refresh cadence and the shared stores.
    private static func connect(store: LiveStore, radar: RadarModel) {
        let alerts = SpotterAlerts.shared
        alerts.start()
        store.wantsLive = { [weak store] in store.map { !$0.isPaused } ?? false }
        store.wantsBackgroundFlights = { SpotterAlerts.shared.needsBackgroundFlights }
        store.onFlights = { [weak store] flights in
            // Background lists carry no routes: take resolved routes and diversions from the enriched list.
            let known = Dictionary(store?.model.flights.map { ($0.id, $0) } ?? [], uniquingKeysWith: { a, _ in a })
            SpotterAlerts.shared.process(FlightListFilter.merging(flights, known: known))
        }
        let source = CadenceSource()
        radar.cadence = { source.interval() }
        store.start()
    }
}

/// Feeds `RefreshCadence` with the latest source and today's request counts. The source is read
/// from `FeedHealth` (an actor) after each fetch, so `interval()` can answer synchronously.
@MainActor
final class CadenceSource {
    private var source: DataSource?

    func interval() -> TimeInterval {
        Task { @MainActor in self.source = await FeedHealth.shared.lastServed?.source }
        let paused = Set(ApiService.allCases.filter { ApiBudget.pausedUntil($0) != nil })
        return RefreshCadence.interval(source: source, counts: ApiBudget.counts, paused: paused,
                                       lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
