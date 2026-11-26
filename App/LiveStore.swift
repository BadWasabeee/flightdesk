import Foundation
import SwiftUI
import CoreLocation
import WidgetKit

/// Owns the location (shared with the widget), the live panel data and the widget refresh pump.
@MainActor
final class LiveStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var settings = AppSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            onSettingsChange?()
            scheduleSettingsReload()
            if settings.radius != oldValue.radius || settings.includeGA != oldValue.includeGA {
                Task { await refresh() }
            }
            if settings.widgetRefreshSeconds != oldValue.widgetRefreshSeconds { scheduleWidgetPump() }
        }
    }
    @Published var model = PanelModel()
    @Published var placeName = Shared.location?.name ?? ""
    @Published var locationStatus = ""
    @Published var lastWidgetReload: Date?

    var onSettingsChange: (() -> Void)?
    /// True while something visible (panel or settings preview) wants live updates.
    var wantsLive: () -> Bool = { false }

    private let locationManager = CLLocationManager()
    private var timers: [Timer] = []
    private var widgetTimer: Timer?

    func start() {
        locationManager.delegate = self
        if Shared.location == nil { requestCurrentLocation() }
        Task { await refresh() }
        timers.append(Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in if self.wantsLive() { await self.refresh() } }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 7, repeats: true) { _ in
            Task { @MainActor in self.rotate() }
        })
        scheduleWidgetPump()
    }

    // MARK: Data

    func refresh() async {
        guard let loc = Shared.location else {
            model.status = "No location — open Settings"
            return
        }
        do {
            let flights = try await FlightService.nearby(lat: loc.lat, lon: loc.lon,
                                                         radiusNM: settings.radius.nm, includeGA: settings.includeGA)
            let keepID = model.featured?.id
            var m = PanelModel(flights: flights, placeName: loc.name, radiusNM: settings.radius.nm, updated: Date())
            m.featuredIndex = flights.firstIndex { $0.id == keepID } ?? 0
            m.status = flights.isEmpty ? "Quiet skies — nothing within \(settings.display.radius(settings.radius.nm))" : ""
            model = m
        } catch {
            model.status = "Can't reach adsb.lol — retrying"
        }
    }

    private func rotate() {
        let n = min(5, model.flights.count)
        guard n > 1 else { return }
        withAnimation(.easeInOut(duration: 0.4)) { model.featuredIndex = (model.featuredIndex + 1) % n }
    }

    // MARK: Widgets

    func reloadWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: Shared.widgetKind)
        lastWidgetReload = Date()
    }

    /// Push settings changes to the widgets right away (debounced while dragging/typing).
    private var settingsReloadTask: Task<Void, Never>?
    private func scheduleSettingsReload() {
        settingsReloadTask?.cancel()
        settingsReloadTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { reloadWidgets() }
        }
    }

    private func scheduleWidgetPump() {
        widgetTimer?.invalidate()
        widgetTimer = Timer.scheduledTimer(withTimeInterval: Double(max(10, settings.widgetRefreshSeconds)), repeats: true) { _ in
            Task { @MainActor in self.reloadWidgets() }
        }
    }

    // MARK: Location

    func setLocation(lat: Double, lon: Double, name: String) {
        Shared.setLocation(lat: lat, lon: lon, name: name)
        placeName = name
        locationStatus = ""
        model = PanelModel()
        Task { await refresh() }
        reloadWidgets()
    }

    func setManualLocation(_ text: String) async -> Bool {
        locationStatus = "Searching…"
        guard let r = await FlightService.resolve(text) else {
            locationStatus = "Couldn't find “\(text)”. Try coordinates, e.g. 39.74, -104.99"
            return false
        }
        setLocation(lat: r.lat, lon: r.lon, name: r.name)
        return true
    }

    func requestCurrentLocation() {
        locationStatus = "Finding your location…"
        switch locationManager.authorizationStatus {
        case .notDetermined: locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            locationStatus = "Location access is off for FlightDesk (System Settings › Privacy & Security › Location Services)."
        default: locationManager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorized: manager.requestLocation()
            case .denied, .restricted: self.locationStatus = "Location access denied — enter a place instead."
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        Task { @MainActor in
            let name = await FlightService.placeName(lat: c.latitude, lon: c.longitude)
            self.setLocation(lat: c.latitude, lon: c.longitude, name: name)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.locationStatus = "Couldn't get your location — enter a place instead." }
    }
}
