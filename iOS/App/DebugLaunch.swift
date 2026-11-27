// DEBUG-only launch options for screenshots and checking layouts without tapping, set through
// `SIMCTL_CHILD_<NAME>=value xcrun simctl launch booted <bundle id>`:
//
//   FLIGHTDESK_UI_TAB=radar|logbook|settings     the sheet's tab
//   FLIGHTDESK_UI_DETENT=peek|medium|large       the sheet's height
//   FLIGHTDESK_UI_SETTINGS=widget|alerts|sources a Settings page
//   FLIGHTDESK_UI_OPEN=nearest                   opens the nearest aircraft once data arrives
//   FLIGHTDESK_UI_URL=flightdesk://…             handles a deep link exactly as .onOpenURL does
//                                                (`simctl openurl` stops at a confirmation alert)
//   FLIGHTDESK_SNAPSHOT_DIR=<dir>                renders every widget face to PNGs in <dir> (relative
//                                                paths go in the app's tmp folder), sample sky with
//                                                FLIGHTDESK_SNAPSHOT_SAMPLE=1, LED/standard with
//                                                FLIGHTDESK_SNAPSHOT_STYLE, light/dark with FLIGHTDESK_SNAPSHOT_SCHEME.

#if DEBUG
import SwiftUI
import WidgetKit

@MainActor
enum DebugLaunch {
    static func run(store: LiveStore, radar: RadarModel) async {
        let env = ProcessInfo.processInfo.environment
        let router = AppRouter.shared
        switch env["FLIGHTDESK_UI_TAB"] {
        case "logbook": router.tab = .logbook
        case "settings": router.tab = .settings
        default: break
        }
        if let page = env["FLIGHTDESK_UI_SETTINGS"].flatMap(SettingsTab.init(rawValue:)) { router.showSettings(page) }
        switch env["FLIGHTDESK_UI_DETENT"] {
        case "peek": router.detent = AppRouter.peek
        case "medium": router.detent = .medium
        case "large": router.detent = .large
        default: break
        }
        if let url = env["FLIGHTDESK_UI_URL"].flatMap(URL.init(string:)) {
            try? await Task.sleep(for: .seconds(3))
            router.open(url)
        }
        if env["FLIGHTDESK_UI_OPEN"] == "nearest" {
            for _ in 0..<60 where radar.flights.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
            // Prefer an airliner with a known route so the detail has a path to draw.
            try? await Task.sleep(for: .seconds(4))
            let sorted = radar.flights.sorted { $0.distance < $1.distance }
            if let f = sorted.first(where: { $0.route != nil }) ?? sorted.first { router.showFlight(hex: f.id, snapshot: f) }
        }
        if let dir = env["FLIGHTDESK_SNAPSHOT_DIR"] { await renderWidgets(to: dir, store: store) }
    }

    /// Every Home Screen size (iPhone 17 Pro points) and every Lock Screen face, to PNGs.
    private static func renderWidgets(to path: String, store: LiveStore) async {
        let env = ProcessInfo.processInfo.environment
        let dir = path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : FileManager.default.temporaryDirectory.appendingPathComponent(path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await AirlineLogos.prefetch(Set((PanelModel.gallery.flights + PanelModel.sample.flights).compactMap(\.logoKey)))
        try? await Task.sleep(for: .seconds(6))
        let live = !store.model.flights.isEmpty && env["FLIGHTDESK_SNAPSHOT_SAMPLE"] == nil
        let m = live ? store.model : PanelModel.gallery
        var o = store.settings.display
        if let style = env["FLIGHTDESK_SNAPSHOT_STYLE"].flatMap(BoardStyle.init(rawValue:)) { o.style = style }
        let scheme: ColorScheme = env["FLIGHTDESK_SNAPSHOT_SCHEME"] == "dark" ? .dark : .light
        let sizes: [(String, PanelLayout, CGSize)] = [
            ("small", .small, CGSize(width: 170, height: 170)),
            ("medium", .medium, CGSize(width: 364, height: 170)),
            ("large", .large, CGSize(width: 364, height: 382)),
        ]
        for (name, layout, size) in sizes {
            render(PanelContent(model: m, layout: layout, accessory: AnyView(RefreshGlyph()))
                .frame(width: size.width, height: size.height)
                .background(o.isStandard ? AnyView(Color.platformBackground) : AnyView(PanelBackground()))
                .environment(\.displayOptions, o)
                .environment(\.colorScheme, scheme)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous)), to: dir.appendingPathComponent("home-\(name).png"))
        }
        let nearest = NearestFlightState(flight: NearestFlightText.nearest(m.flights), units: o.units, status: "Quiet skies")
        let quiet = NearestFlightState(flight: nil, units: o.units, status: "Quiet skies")
        // The Lock Screen draws faces in white over the wallpaper; a dark backdrop stands in for it.
        let faces: [(String, AnyView, CGSize)] = [
            ("lock-circular", AnyView(NearestCircularView(state: nearest)), CGSize(width: 76, height: 76)),
            ("lock-rectangular", AnyView(NearestRectangularView(state: nearest)), CGSize(width: 172, height: 76)),
            ("lock-inline", AnyView(NearestInlineView(state: nearest)), CGSize(width: 257, height: 26)),
            ("lock-circular-quiet", AnyView(NearestCircularView(state: quiet)), CGSize(width: 76, height: 76)),
            ("lock-rectangular-quiet", AnyView(NearestRectangularView(state: quiet)), CGSize(width: 172, height: 76)),
        ]
        for (name, view, size) in faces {
            render(view
                .frame(width: size.width, height: size.height)
                .foregroundStyle(.white)
                .padding(12)
                .background(Color(red: 0.12, green: 0.2, blue: 0.35))
                .environment(\.colorScheme, .dark), to: dir.appendingPathComponent("\(name).png"))
        }
        print("FlightDesk snapshots written to \(dir.path)")
    }

    private static func render<V: View>(_ view: V, to url: URL) {
        let r = ImageRenderer(content: view)
        r.scale = 3
        guard let png = r.uiImage?.pngData() else { return }
        try? png.write(to: url)
    }
}
#endif
