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
            controller.onClose = { controllers[key] = nil }
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

/// Owns one detail window and its live model; polling stops when the window closes.
@MainActor
private final class FlightDetailWindowController: NSWindowController, NSWindowDelegate {
    private let model: FlightDetailModel
    private var titleSubscription: AnyCancellable?
    var onClose: (() -> Void)?

    init(hex: String, snapshot: Flight?) {
        model = FlightDetailModel(hex: hex, snapshot: snapshot)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 620, height: 420)
        window.contentViewController = NSHostingController(rootView: FlightDetailView(model: model))
        window.setContentSize(NSSize(width: 760, height: 560))
        window.center()
        super.init(window: window)
        window.delegate = self
        titleSubscription = model.$flight
            .map { FlightDetailModel.title(for: $0, hex: hex) }
            .removeDuplicates()
            .sink { [weak window] in window?.title = $0 }
        model.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        titleSubscription = nil
        onClose?()
    }
}
