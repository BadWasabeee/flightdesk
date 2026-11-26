import Cocoa
import SwiftUI
import ServiceManagement

@main
enum FlightDeskMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
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

    func applicationDidFinishLaunching(_ note: Notification) {
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
            return self.panel.isVisible || (self.settingsWindow?.isVisible ?? false)
        }
        applyPanelSettings()
        store.start()

        if !UserDefaults.standard.bool(forKey: "onboarded.v2") {
            UserDefaults.standard.set(true, forKey: "onboarded.v2")
            openSettings(tab: .widget)
        }
        runSnapshotIfRequested()
    }

    // Clicking the widget (or relaunching the app) opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(tab: settingsTab)
        return true
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
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(o.isGlass ? Color.white.opacity(0.62) : o.theme.color.opacity(0.55))))
                    .frame(width: size.width, height: size.height)
                    .environment(\.displayOptions, o)
                    .background(o.isGlass ? AnyView(LinearGradient(colors: [Color(red: 0.16, green: 0.32, blue: 0.55), Color(red: 0.55, green: 0.38, blue: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyView(PanelBackground()))
                    .environment(\.displayOptions, o)
                    .environment(\.colorScheme, o.isGlass ? .dark : .light)
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
