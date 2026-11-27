import Cocoa
import Combine
import MapKit
import SwiftUI

/// The app's main window: nearby aircraft in a sidebar, a live map and an inspector, or the full
/// detail of one flight in place of the map, or Settings. The window is created when first shown
/// and released when closed (its frame is autosaved). Flight details and Settings opened anywhere
/// in the app come here.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    private let store: LiveStore
    private(set) var window: NSWindow?
    private var radar: RadarModel?
    /// The Settings tab last shown, reopened by ⌘, (kept across window closes).
    private var lastSettingsTab = SettingsTab.general
    private var tabSubscription: AnyCancellable?
    private static let autosaveName = "FlightDeskMainWindow"

    init(store: LiveStore) {
        self.store = store
        super.init()
        FlightDetail.presenter = { [weak self] hex, snapshot in self?.showDetail(hex: hex, snapshot: snapshot) }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    @objc func showWindow(_ sender: Any?) {
        if window == nil { makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(sender)
        radar?.setActive(true)
    }

    /// Opens the main window on the detail of the aircraft with `hex` (deep links, alerts, panel).
    func showDetail(hex: String, snapshot: Flight?) {
        showWindow(nil)
        let snap = snapshot ?? store.model.flights.first { $0.id.caseInsensitiveCompare(hex) == .orderedSame }
        withAnimation(Self.motion) { radar?.showDetail(hex: hex, snapshot: snap) }
    }

    /// Opens the main window on the live map, leaving Settings and any flight detail (Shortcuts' Open Radar).
    func showRadar() {
        showWindow(nil)
        guard let radar else { return }
        withAnimation(Self.motion) {
            radar.closeSettings()
            radar.closeDetail()
        }
    }

    /// Opens the main window on Settings at `tab`, or at the tab last shown.
    func showSettings(_ tab: SettingsTab? = nil) {
        showWindow(nil)
        guard let radar else { return }
        let tab = tab ?? lastSettingsTab
        let entering = radar.settingsTab == nil
        withAnimation(Self.motion) { radar.showSettings(tab) }
        // Don't drop the cursor into the pane's first text field; Tab moves into it.
        if entering { DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) } }
    }

    /// The window's view transitions, or none with Reduce Motion.
    static var motion: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    // MARK: Actions

    /// View › Refresh: refetches the map's aircraft and the store (panel and widgets).
    @objc func refresh(_ sender: Any?) {
        if let radar { Task { await radar.refresh() } }
        Task { await store.refresh() }
    }

    @objc func toggleFlightList(_ sender: Any?) {
        guard let radar else { return }
        withAnimation(Self.motion) { radar.sidebar = radar.sidebar == .detailOnly ? .all : .detailOnly }
    }

    /// File › Open Details: the selected aircraft's detail, in the window.
    @objc func openSelectedDetails(_ sender: Any?) {
        guard let radar, let id = radar.selection else { return }
        withAnimation(Self.motion) { radar.showDetail(hex: id, snapshot: radar.selected) }
    }

    /// File › Open in New Window: the selected (or shown) aircraft in a separate detail window.
    @objc func openSelectedInNewWindow(_ sender: Any?) {
        guard let radar, let id = radar.detail?.hex ?? radar.selection else { return }
        FlightDetail.showInNewWindow(hex: id, snapshot: radar.detail == nil ? radar.selected : radar.detailFlight)
    }

    /// View › Back (⌘[): from Settings to the map or detail, or from a detail to the map.
    @objc func goBack(_ sender: Any?) {
        withAnimation(Self.motion) { _ = radar?.goBack() }
    }

    /// Esc, when nothing in the window handled it.
    @objc func cancelOperation(_ sender: Any?) {
        withAnimation(Self.motion) { _ = radar?.cancel() }
    }

    /// Edit › Find (⌘F): focuses the sidebar's search field, showing the sidebar if needed.
    @objc func focusSearch(_ sender: Any?) {
        guard let radar, let window else { return }
        let focus = { [weak window] in
            guard let window, let field = Self.searchField(in: window.contentView?.superview ?? window.contentView) else { return }
            window.makeFirstResponder(field)
        }
        if radar.settingsTab != nil || radar.sidebar == .detailOnly {
            withAnimation(Self.motion) { radar.closeSettings() }
            radar.sidebar = .all
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                focus()
            }
        } else {
            focus()
        }
    }

    /// View › Sort By (the item's tag indexes `FlightSort.allCases`).
    @objc func setSort(_ sender: NSMenuItem) {
        guard FlightSort.allCases.indices.contains(sender.tag) else { return }
        radar?.sort = FlightSort.allCases[sender.tag]
    }

    /// View › Airlines Only.
    @objc func toggleAirlinesOnly(_ sender: Any?) { store.settings.includeGA.toggle() }

    /// View › Center on My Location (⌘L).
    @objc func recenter(_ sender: Any?) {
        guard let radar else { return }
        withAnimation(Self.motion) {
            radar.closeSettings()
            radar.closeLogbook()
            radar.closeDetail()
        }
        radar.recenter()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let key = window?.isKeyWindow == true
        switch item.action {
        case #selector(toggleFlightList(_:)):
            item.title = radar?.sidebar == .detailOnly ? "Show Sidebar" : "Hide Sidebar"
            return key
        case #selector(openSelectedDetails(_:)):
            return key && radar?.selection != nil && radar?.selection != radar?.detail?.hex
        case #selector(openSelectedInNewWindow(_:)):
            return key && (radar?.detail != nil || radar?.selection != nil)
        case #selector(goBack(_:)):
            return key && (radar?.detail != nil || radar?.settingsTab != nil || radar?.showsLogbook == true)
        case #selector(focusSearch(_:)):
            return key
        case #selector(setSort(_:)):
            item.state = radar.map { FlightSort.allCases.firstIndex(of: $0.sort) == item.tag } == true ? .on : .off
            return key
        case #selector(toggleAirlinesOnly(_:)):
            item.state = store.settings.includeGA ? .off : .on
            return true
        case #selector(recenter(_:)):
            return key && Shared.location != nil
        default:
            return true
        }
    }

    private static func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        for sub in view.subviews { if let f = searchField(in: sub) { return f } }
        return nil
    }

    // MARK: Window

    private func makeWindow() {
        let radar = RadarModel(store: store)
        let host = NSHostingController(rootView: MainWindowView(store: store, radar: radar))
        host.sizingOptions = [.minSize]
        host.sceneBridgingOptions = [.toolbars, .title]
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = host
        w.title = "FlightDesk"
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.delegate = self
        if !w.setFrameUsingName(Self.autosaveName) {
            w.setContentSize(NSSize(width: 1120, height: 720))
            w.center()
        }
        w.setFrameAutosaveName(Self.autosaveName)
        window = w
        self.radar = radar
        tabSubscription = radar.$settingsTab.compactMap { $0 }.sink { [weak self] in self?.lastSettingsTab = $0 }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        radar?.setActive(window.occlusionState.contains(.visible))
    }

    func windowWillClose(_ notification: Notification) {
        radar?.setActive(false)
        radar?.closeDetail()
        radar = nil
        window = nil
    }
}

extension AppDelegate {
    /// Shows the main window (status menu, Dock and launch).
    @objc func showMainWindow() { mainWindow.showWindow(nil) }
}

/// How the app was started.
enum LaunchContext {
    /// True when macOS opened the app as a login item. Only meaningful while launching, when the
    /// "open application" Apple event is current.
    static var isLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}
