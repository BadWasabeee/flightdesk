import Cocoa
import Combine
import SwiftUI

/// Flight detail window (map + flight info), opened from the widget via `FlightLink`.
/// Contract: `FlightDetail.show(hex:snapshot:)` opens (or focuses) a window for the aircraft with that ICAO hex.
@MainActor
enum FlightDetail {
    /// Open windows by lowercase hex; an entry is removed when its window closes.
    private static var controllers: [String: FlightDetailWindowController] = [:]

    /// Shows the detail window for `hex`, creating it if needed. `snapshot` fills a new window
    /// immediately while live data loads; it is ignored when the window already exists.
    static func show(hex: String, snapshot: Flight? = nil) {
        let key = hex.lowercased()
        let controller: FlightDetailWindowController
        if let existing = controllers[key] {
            controller = existing
        } else {
            controller = FlightDetailWindowController(hex: key, snapshot: snapshot)
            controller.onClose = { [weak controller] in
                controllers = controllers.filter { $0.value !== controller }
            }
            // Clicking another plane switches this window to it; re-key so the widget finds it.
            controller.onSwitch = { [weak controller] newHex in
                guard let controller else { return }
                controllers = controllers.filter { $0.value !== controller }
                controllers[newHex] = controller
            }
            // Offset from an already open detail window instead of stacking exactly on top of it.
            if let other = controllers.values.compactMap(\.window).first(where: \.isVisible), let window = controller.window {
                window.setFrameTopLeftPoint(NSPoint(x: other.frame.minX + 24, y: other.frame.maxY - 24))
            }
            controllers[key] = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

/// The aircraft a detail window is showing. Clicking another plane on the map switches it.
@MainActor
final class FlightDetailNavigator: ObservableObject {
    @Published private(set) var model: FlightDetailModel
    var onSwitch: ((FlightDetailModel) -> Void)?

    init(hex: String, snapshot: Flight?) {
        model = FlightDetailModel(hex: hex, snapshot: snapshot)
    }

    func select(_ flight: Flight) {
        guard flight.id != model.hex else { return }
        model.stop()
        // Keep the other aircraft (and the one being left) on the map while the new one loads.
        let others = model.nearby + [model.flight].compactMap { $0 }
        model = FlightDetailModel(hex: flight.id, snapshot: flight, nearby: others)
        model.start()
        onSwitch?(model)
    }
}

private struct FlightDetailRoot: View {
    @ObservedObject var navigator: FlightDetailNavigator
    var body: some View {
        FlightDetailView(model: navigator.model)
            .id(navigator.model.hex)
            .environment(\.openFlightDetail) { navigator.select($0) }
    }
}

/// Owns one detail window and its live model; polling stops when the window closes.
@MainActor
private final class FlightDetailWindowController: NSWindowController, NSWindowDelegate {
    private let navigator: FlightDetailNavigator
    private var titleSubscription: AnyCancellable?
    var onClose: (() -> Void)?
    var onSwitch: ((String) -> Void)?

    init(hex: String, snapshot: Flight?) {
        navigator = FlightDetailNavigator(hex: hex, snapshot: snapshot)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 620, height: 420)
        window.contentViewController = NSHostingController(rootView: FlightDetailRoot(navigator: navigator))
        window.setContentSize(NSSize(width: 860, height: 600))
        window.center()
        super.init(window: window)
        window.delegate = self
        navigator.onSwitch = { [weak self] model in
            self?.observeTitle(of: model)
            self?.onSwitch?(model.hex)
        }
        observeTitle(of: navigator.model)
        navigator.model.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func observeTitle(of model: FlightDetailModel) {
        let hex = model.hex
        titleSubscription = model.$flight
            .map { FlightDetailModel.title(for: $0, hex: hex) }
            .removeDuplicates()
            .sink { [weak window] in window?.title = $0 }
    }

    func windowWillClose(_ notification: Notification) {
        navigator.model.stop()
        titleSubscription = nil
        onClose?()
    }
}
