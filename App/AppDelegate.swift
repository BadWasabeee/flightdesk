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
    private var welcomeWindow: NSWindow?
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    lazy var mainWindow = MainWindowController(store: store)
    /// A window opened by a reopen or launch, held briefly so a deep link arriving
    /// around the same time (widget click) can cancel it.
    private var pendingWindow: DispatchWorkItem?
    /// When the last `flightdesk://` link was handled.
    private var lastLinkOpen = Date.distantPast
    /// Links delivered before launch finished.
    private var pendingLinks: [String] = []
    private var didLaunch = false
    /// A deep link or intent has been handled (used to keep a launch it triggered from opening the main window).
    private var openedFromLink = false
    /// A Settings deep link that arrived before launch finished.
    private var pendingSettingsTab: SettingsTab?

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
        // Borderless windows keep a stale shadow when their content resizes.
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            // Delivered on the main queue.
            MainActor.assumeIsolated { self?.panel.invalidateShadow() }
        }
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
            // The main window covers Settings, whose Display preview shows the live board.
            return self.panel.isVisible || self.mainWindow.isVisible
        }
        applyPanelSettings()
        installSpotterAlerts()
        store.start()

        didLaunch = true
        pendingLinks.forEach { showFlight(hex: $0) }
        pendingLinks.removeAll()
        if let tab = pendingSettingsTab {
            pendingSettingsTab = nil
            openSettings(tab: tab)
        }
        pendingIntentActions.forEach { $0(self) }
        pendingIntentActions.removeAll()

        // A normal launch opens the main window, with onboarding in front the first time. Launched by
        // a deep link the detail window wins; launched at login the app starts in the menu bar only.
        // (`launchIsDefaultUserInfoKey` isn't reliable here; a deep link arriving during launch
        // cancels this scheduled window instead.)
        if !loginLaunch, !openedFromLink {
            scheduleWindow {
                $0.showMainWindow()
                guard !UserDefaults.standard.bool(forKey: "onboarded.v2") else { return }
                UserDefaults.standard.set(true, forKey: "onboarded.v2")
                $0.showWelcome()
            }
        }
        #if DEBUG
        runSnapshotIfRequested()
        #endif
    }

    // Clicking the Dock icon or an empty part of the widget opens the main window when no window
    // is open (the desktop panel doesn't count).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard Date().timeIntervalSince(lastLinkOpen) > 1 else { return true }
        if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
            scheduleWindow { $0.showMainWindow() }
        }
        return true
    }

    // The menu bar item, desktop panel and widget refreshes keep running without windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Deep links

    /// `flightdesk://flight/<hex>` from the widget opens that aircraft's detail window.
    func application(_ application: NSApplication, open urls: [URL]) {
        // flightdesk://settings/<general|display|widget|alerts|sources> opens that Settings tab in the main window.
        if let tab = urls.lazy.compactMap(SettingsTab.init(url:)).first {
            lastLinkOpen = Date()
            openedFromLink = true
            pendingWindow?.cancel()
            pendingWindow = nil
            // During launch the main window isn't set up yet; open it once launch finishes.
            if didLaunch { openSettings(tab: tab) } else { pendingSettingsTab = tab }
        }
        let hexes = urls.compactMap(FlightLink.hex(from:))
        guard !hexes.isEmpty else { return }
        lastLinkOpen = Date()
        pendingWindow?.cancel()
        pendingWindow = nil
        openedFromLink = true
        if didLaunch { hexes.forEach(showFlight(hex:)) } else { pendingLinks += hexes }
    }

    // MARK: Shortcuts and Siri

    /// Actions from intents that arrived before launch finished.
    private var pendingIntentActions: [@MainActor (AppDelegate) -> Void] = []

    /// Runs an intent that shows something in the main window. Like a deep link, it replaces the
    /// window a launch would otherwise open; before launch finishes it waits for it.
    func performIntent(_ action: @escaping @MainActor (AppDelegate) -> Void) {
        lastLinkOpen = Date()
        openedFromLink = true
        pendingWindow?.cancel()
        pendingWindow = nil
        if didLaunch { action(self) } else { pendingIntentActions.append(action) }
    }

    /// A spoken or Shortcuts answer is running without UI: a launch it caused shouldn't open the
    /// main window (the reopen/launch window is only pending for a moment after launch).
    func intentWillAnswer() {
        if didLaunch {
            pendingWindow?.cancel()
            pendingWindow = nil
        } else {
            openedFromLink = true
        }
    }

    private func showFlight(hex: String) {
        FlightDetail.show(hex: hex, snapshot: store.model.flights.first { $0.id == hex })
    }

    /// Opens a window after a short grace period, unless a deep link cancels it first.
    /// The system's reopen and open-URL events for one widget click can arrive in either order.
    private func scheduleWindow(_ open: @escaping @MainActor (AppDelegate) -> Void) {
        pendingWindow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingWindow = nil
                open(self)
            }
        }
        pendingWindow = work
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

    /// The status menu is open (it rebuilds in place when fresh data arrives).
    private var menuIsOpen = false

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        // Nothing visible keeps `store.model` fresh, so fetch now if it's old and update the open menu.
        guard Date().timeIntervalSince(store.model.updated ?? .distantPast) > 30 else { return }
        Task {
            await store.refresh()
            if menuIsOpen { menuNeedsUpdate(menu) }
        }
    }

    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add("Open FlightDesk", #selector(showMainWindow), "o")
        menu.addItem(.separator())

        // Live: the nearest few aircraft, each opening its detail window.
        if store.placeName.isEmpty {
            add("Set Your Location…", #selector(showLocationSettings)).image = symbol("location")
        } else {
            menu.addItem(.sectionHeader(title: "Near \(store.placeName)"))
            let nearest = store.model.flights.sorted { $0.distance < $1.distance }.prefix(3)
            if nearest.isEmpty {
                let status = store.model.status.isEmpty ? "Looking for aircraft…" : store.model.status
                menu.addItem(withTitle: status, action: nil, keyEquivalent: "").isEnabled = false
            }
            for f in nearest {
                let item = add(Self.menuTitle(for: f, phase: store.model.runwayPhases[f.id], display: store.settings.display),
                               #selector(openFlightFromMenu(_:)))
                item.representedObject = f.id
                item.image = symbol("airplane")
                item.toolTip = [f.airlineName, f.typeCode].filter { !$0.isEmpty }.joined(separator: " · ")
            }
        }
        menu.addItem(.separator())
        add("Show Live Desktop Panel", #selector(togglePanel)).state = store.settings.showPanel ? .on : .off
        add("Refresh Now", #selector(refreshWidgets), "r")
        menu.addItem(.separator())
        add("Settings…", #selector(showSettings), ",")
        add("About FlightDesk", #selector(about))
        add("FlightDesk on GitHub", #selector(openGitHub))
        menu.addItem(.separator())
        add("Quit FlightDesk", #selector(quit), "q")
    }

    /// "DL1342  MKE→BOS · 4.0 nm NE" (route only when known), with any situation ("· DIVERT MKE")
    /// and runway phase ("· Final 28C").
    static func menuTitle(for f: Flight, phase: RunwayPhase? = nil, display: DisplayOptions) -> String {
        let d = display.withStandardStyle
        var parts: [String] = []
        if let r = f.route, let to = f.destination, !r.from.code.isEmpty, !to.code.isEmpty { parts.append("\(r.from.code)→\(to.code)") }
        else if !f.typeCode.isEmpty { parts.append(f.typeCode) }
        if let s = f.situation { parts.append(s.tag) }
        if let tag = phase?.tag(d, distance: false) { parts.append(tag) }
        parts.append("\(d.distance(f.distance)) \(f.direction)")
        return "\(f.displayNumber)  " + parts.joined(separator: " · ")
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    @discardableResult
    private func add(_ title: String, _ sel: Selector, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
        return i
    }

    @objc private func openFlightFromMenu(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        showFlight(hex: hex)
    }

    @objc private func showLocationSettings() { openSettings(tab: .general) }

    @objc func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.aboutCredits()])
    }

    /// Centered, linked credits for the data sources.
    private static func aboutCredits() -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 2
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ]
        let out = NSMutableAttributedString()
        for (i, c) in DataCredits.all.enumerated() {
            out.append(NSAttributedString(string: "\(c.role): ", attributes: base))
            var link = base
            link[.link] = c.url
            out.append(NSAttributedString(string: c.name, attributes: link))
            if i < DataCredits.all.count - 1 { out.append(NSAttributedString(string: "\n", attributes: base)) }
        }
        var gh = base
        gh[.link] = URL(string: "https://github.com/BadWasabeee/flightdesk")!
        out.append(NSAttributedString(string: "\n\n", attributes: base))
        out.append(NSAttributedString(string: "Open source on GitHub", attributes: gh))
        return out
    }

    @objc func openGitHub() { NSWorkspace.shared.open(URL(string: "https://github.com/BadWasabeee/flightdesk")!) }
    /// ⌘, and the status menu: Settings in the main window, at the tab last shown.
    @objc func showSettings() {
        mainWindow.showSettings()
        Task { await store.refresh() }
    }
    @objc func refreshWidgets() { store.reloadWidgets(); Task { await store.refresh() } }
    @objc func togglePanel() { store.settings.showPanel.toggle() }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: Settings

    /// Opens the main window on Settings at `tab` (deep links, location prompts, the welcome window).
    func openSettings(tab: SettingsTab) {
        mainWindow.showSettings(tab)
        Task { await store.refresh() }
    }

    // MARK: Welcome

    /// The first-run window: location, widget and alerts in one place.
    @objc func showWelcome() {
        if let w = welcomeWindow { w.makeKeyAndOrderFront(nil); return }
        let view = WelcomeView(store: store,
                               onSetUpAlerts: { [weak self] in self?.closeWelcome(); self?.openSettings(tab: .alerts) },
                               onDone: { [weak self] in self?.closeWelcome() })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Welcome to FlightDesk"
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.center()
        welcomeWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { w.makeFirstResponder(nil) }
    }

    private func closeWelcome() {
        welcomeWindow?.close()
        welcomeWindow = nil
    }

    // MARK: Debug snapshots

    #if DEBUG
    /// FLIGHTDESK_SNAPSHOT_DIR=/path renders every widget size, the designed empty/error states
    /// the situation labels (a diversion and an emergency, `alert-*`), a flight on final (`approach-*`)
    /// and the floating panel to PNGs,
    /// then quits. FLIGHTDESK_SNAPSHOT_SAMPLE=1 uses the gallery sky;
    /// FLIGHTDESK_SNAPSHOT_STYLE=led|standard and FLIGHTDESK_SNAPSHOT_SCHEME=light|dark override the look.
    /// Debug builds only; under the App Sandbox the directory must be inside the app's container
    /// (for example `~/Library/Containers/<bundle id>/Data/tmp`).
    private func runSnapshotIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["FLIGHTDESK_SNAPSHOT_DIR"] else { return }
        let alerts = PanelModel.situations
        var emergency = alerts
        emergency.featuredIndex = 1
        Task { await AirlineLogos.prefetch(Set((alerts.flights + PanelModel.approach.flights + PanelModel.sample.flights).compactMap(\.logoKey))) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            let env = ProcessInfo.processInfo.environment
            let m = (self.store.model.flights.isEmpty || env["FLIGHTDESK_SNAPSHOT_SAMPLE"] != nil) ? PanelModel.gallery : self.store.model
            var o = self.store.settings.display
            if let style = env["FLIGHTDESK_SNAPSHOT_STYLE"].flatMap(BoardStyle.init(rawValue:)) { o.style = style }
            let scheme: ColorScheme = env["FLIGHTDESK_SNAPSHOT_SCHEME"] == "dark" ? .dark : .light
            let small = CGSize(width: 170, height: 170), medium = CGSize(width: 364, height: 170)
            let large = CGSize(width: 364, height: 382), xlarge = CGSize(width: 765, height: 382)
            var noList = o
            noList.showList = false
            func state(_ status: String) -> PanelModel {
                var s = PanelModel(radiusNM: 25)
                s.status = status
                s.placeName = status.contains("location") ? "" : "Denver"
                return s
            }
            let shots: [(String, PanelModel, PanelLayout, CGSize, DisplayOptions)] = [
                ("small", m, .small, small, o),
                ("medium", m, .medium, medium, o),
                ("large", m, .large, large, o),
                ("xlarge", m, .extraLarge, xlarge, o),
                ("large-few", PanelModel.sample, .large, large, o),
                ("large-nolist", m, .large, large, noList),
                ("xlarge-nolist", m, .extraLarge, xlarge, noList),
                ("state-quiet-medium", state("Quiet skies — Nothing within \(o.radius(25)) right now"), .medium, medium, o),
                ("state-offline-small", state("Can’t reach flight data — Retrying in a couple of minutes"), .small, small, o),
                ("state-nolocation-medium", state("No location set — Choose one in FlightDesk or with Edit Widget"), .medium, medium, o),
                ("state-loading-large", state(""), .large, large, o),
                ("alert-small", alerts, .small, small, o),
                ("alert-small-emergency", emergency, .small, small, o),
                ("alert-medium", alerts, .medium, medium, o),
                ("alert-medium-emergency", emergency, .medium, medium, o),
                ("alert-large", alerts, .large, large, o),
                ("alert-large-emergency", emergency, .large, large, o),
                ("alert-xlarge", alerts, .extraLarge, xlarge, o),
                ("alert-large-nolist", alerts, .large, large, noList),
                ("approach-small", PanelModel.approach, .small, small, o),
                ("approach-medium", PanelModel.approach, .medium, medium, o),
                ("approach-large", PanelModel.approach, .large, large, o),
                ("approach-xlarge", PanelModel.approach, .extraLarge, xlarge, o),
            ]
            for (name, model, layout, size, opts) in shots {
                self.render(PanelContent(model: model, layout: layout, accessory: AnyView(RefreshGlyph()))
                    .frame(width: size.width, height: size.height)
                    .background(opts.isStandard ? AnyView(Color(nsColor: .windowBackgroundColor)) : AnyView(PanelBackground()))
                    .environment(\.displayOptions, opts)
                    .environment(\.colorScheme, scheme)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)), to: "\(dir)/\(name).png")
            }
            // The floating desktop panel, with its chrome.
            self.render(PanelContent(model: m, layout: .panel)
                .environment(\.displayOptions, o)
                .frame(width: 460)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(PanelChrome(options: o))
                .padding(20)
                .environment(\.colorScheme, scheme), to: "\(dir)/panel.png")
            self.render(PanelContent(model: alerts, layout: .panel)
                .environment(\.displayOptions, o)
                .frame(width: 460)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(PanelChrome(options: o))
                .padding(20)
                .environment(\.colorScheme, scheme), to: "\(dir)/alert-panel.png")
            self.render(PanelContent(model: PanelModel.approach, layout: .panel)
                .environment(\.displayOptions, o)
                .frame(width: 460)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(PanelChrome(options: o))
                .padding(20)
                .environment(\.colorScheme, scheme), to: "\(dir)/approach-panel.png")
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
    #endif
}
