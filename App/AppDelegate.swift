import Cocoa
import SwiftUI
import ServiceManagement

@main
enum FlightDeskMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

/// Floating live panel content.
struct PanelRoot: View {
    @ObservedObject var store: LiveStore
    var body: some View {
        let o = store.settings.display
        PanelContent(model: store.model, layout: .panel)
            .environment(\.displayOptions, o)
            .environment(\.flightLinkStyle, .action { FlightDetail.show(hex: $0.id, snapshot: $0) })
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(PanelChrome(options: o))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let store = LiveStore()
    var panel: NSWindow!
    var settingsWindow: NSWindow?
    var settingsTab = SettingsTab.general
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    lazy var mainWindow = MainWindowController(store: store)
    /// A window opened by a reopen or launch, held briefly so a deep link arriving
    /// around the same time (widget click) can cancel it.
    private var pendingSettings: DispatchWorkItem?
    /// When the last `flightdesk://` link was handled.
    private var lastLinkOpen = Date.distantPast
    /// Links delivered before launch finished.
    private var pendingLinks: [String] = []
    private var didLaunch = false

    func applicationDidFinishLaunching(_ note: Notification) {
        let loginLaunch = LaunchContext.isLoginItem
        MainMenu.install(for: self)
        let host = NSHostingController(rootView: PanelRoot(store: store))
        host.sizingOptions = [.preferredContentSize]
        panel = NSWindow(contentViewController: host)
        panel.styleMask = [.borderless]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        host.view.menu = menu
        if !panel.setFrameUsingName("FlightDeskWindow"), let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - 484, y: v.maxY - 300))
        }
        panel.setFrameAutosaveName("FlightDeskWindow")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "airplane", accessibilityDescription: "FlightDesk")
        statusItem.menu = menu
        menu.delegate = self

        store.onSettingsChange = { [weak self] in self?.applyPanelSettings() }
        store.wantsLive = { [weak self] in
            guard let self else { return false }
            return self.panel.isVisible || (self.settingsWindow?.isVisible ?? false) || self.mainWindow.isVisible
        }
        applyPanelSettings()
        installSpotterAlerts()
        store.start()

        didLaunch = true
        pendingLinks.forEach { showFlight(hex: $0) }
        pendingLinks.removeAll()

        // A normal launch opens the main window, with onboarding in front the first time. Launched by
        // a deep link the detail window wins; launched at login the app starts in the menu bar only.
        let defaultLaunch = note.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if defaultLaunch, !loginLaunch {
            scheduleSettings {
                $0.showMainWindow()
                guard !UserDefaults.standard.bool(forKey: "onboarded.v2") else { return }
                UserDefaults.standard.set(true, forKey: "onboarded.v2")
                $0.openSettings(tab: .widget)
            }
        }
        runSnapshotIfRequested()
    }

    // Clicking the Dock icon or an empty part of the widget opens the main window when no window
    // is open (the desktop panel doesn't count).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard Date().timeIntervalSince(lastLinkOpen) > 1 else { return true }
        if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
            scheduleSettings { $0.showMainWindow() }
        }
        return true
    }

    // The menu bar item, desktop panel and widget refreshes keep running without windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Deep links

    /// `flightdesk://flight/<hex>` from the widget opens that aircraft's detail window.
    func application(_ application: NSApplication, open urls: [URL]) {
        let hexes = urls.compactMap(FlightLink.hex(from:))
        guard !hexes.isEmpty else { return }
        lastLinkOpen = Date()
        pendingSettings?.cancel()
        pendingSettings = nil
        if didLaunch { hexes.forEach(showFlight(hex:)) } else { pendingLinks += hexes }
    }

    private func showFlight(hex: String) {
        FlightDetail.show(hex: hex, snapshot: store.model.flights.first { $0.id == hex })
    }

    /// Opens a window after a short grace period, unless a deep link cancels it first.
    /// The system's reopen and open-URL events for one widget click can arrive in either order.
    private func scheduleSettings(_ open: @escaping @MainActor (AppDelegate) -> Void) {
        pendingSettings?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingSettings = nil
                open(self)
            }
        }
        pendingSettings = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func applyPanelSettings() {
        panel.level = store.settings.keepOnTop ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        if store.settings.showPanel {
            if !panel.isVisible { panel.orderFront(nil); Task { await store.refresh() } }
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add("Open FlightDesk", #selector(showMainWindow))
        let place = store.placeName.isEmpty ? "No location set" : "Location: \(store.placeName)"
        menu.addItem(withTitle: place, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        add("About FlightDesk", #selector(about))
        add("Settings…", #selector(showSettings), ",")
        add("Refresh Widgets Now", #selector(refreshWidgets), "r")
        add("Show Live Desktop Panel", #selector(togglePanel)).state = store.settings.showPanel ? .on : .off
        add("Launch at Login", #selector(toggleLogin)).state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        add("FlightDesk on GitHub", #selector(openGitHub))
        add("Quit FlightDesk", #selector(quit), "q")
    }

    @discardableResult
    private func add(_ title: String, _ sel: Selector, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
        return i
    }

    @objc func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Live aircraft from adsb.lol · routes & aircraft from adsbdb.com",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }
    @objc func openGitHub() { NSWorkspace.shared.open(URL(string: "https://github.com/BadWasabeee/flightdesk")!) }
    @objc func showSettings() { openSettings(tab: settingsTab) }
    @objc func refreshWidgets() { store.reloadWidgets(); Task { await store.refresh() } }
    @objc func togglePanel() { store.settings.showPanel.toggle() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        else { try? SMAppService.mainApp.register() }
    }

    // MARK: Settings window

    func openSettings(tab: SettingsTab) {
        settingsTab = tab
        let root = SettingsView(store: store, tab: tab) { [weak self] in self?.settingsTab = $0 }
        if let w = settingsWindow {
            // Rebuild so the requested tab is selected.
            w.contentViewController = NSHostingController(rootView: root)
        } else {
            let w = NSWindow(contentViewController: NSHostingController(rootView: root))
            w.title = "FlightDesk Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        Task { await store.refresh() }
    }

    // MARK: Debug snapshots

    /// FLIGHTDESK_SNAPSHOT_DIR=/path renders every widget size + the panel to PNGs, then quits.
    private func runSnapshotIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["FLIGHTDESK_SNAPSHOT_DIR"] else { return }
        Task { await AirlineLogos.prefetch(Set(PanelModel.sample.flights.compactMap(\.logoKey))) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            let env = ProcessInfo.processInfo.environment
            let m = (self.store.model.flights.isEmpty || env["FLIGHTDESK_SNAPSHOT_SAMPLE"] != nil) ? PanelModel.sample : self.store.model
            var o = self.store.settings.display
            if let style = env["FLIGHTDESK_SNAPSHOT_STYLE"].flatMap(BoardStyle.init(rawValue:)) { o.style = style }
            let sizes: [(String, PanelLayout, CGSize)] = [
                ("small", .small, CGSize(width: 170, height: 170)),
                ("medium", .medium, CGSize(width: 364, height: 170)),
                ("large", .large, CGSize(width: 364, height: 382)),
                ("xlarge", .extraLarge, CGSize(width: 765, height: 382)),
            ]
            for (name, layout, size) in sizes {
                self.render(PanelContent(model: m, layout: layout, accessory: AnyView(Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(o.isStandard ? Color.secondary : o.theme.color.opacity(0.55))))
                    .frame(width: size.width, height: size.height)
                    .environment(\.displayOptions, o)
                    .background(o.isStandard ? AnyView(Color(nsColor: .windowBackgroundColor)) : AnyView(PanelBackground()))
                    .environment(\.displayOptions, o)
                    .environment(\.colorScheme, env["FLIGHTDESK_SNAPSHOT_SCHEME"] == "dark" ? .dark : .light)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)), to: "\(dir)/\(name).png")
            }
            NSApp.terminate(nil)
        }
    }

    private func render<V: View>(_ view: V, to path: String) {
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let tiff = r.nsImage?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
