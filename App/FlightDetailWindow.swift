import Cocoa
import Combine
import SwiftUI

/// Entry point for showing an aircraft's details.
/// Contract: `FlightDetail.show(hex:snapshot:)` presents details for the aircraft with that ICAO hex:
/// in the main window when a `presenter` is installed, otherwise in a separate window.
@MainActor
enum FlightDetail {
    /// When set (by the main window), `show` presents details there instead of opening a window.
    static var presenter: (@MainActor (String, Flight?) -> Void)?

    /// Open windows by lowercase hex; an entry is removed when its window closes.
    private static var controllers: [String: FlightDetailWindowController] = [:]

    /// Shows details for `hex` via the `presenter` when one is installed, else in a window.
    /// `snapshot` fills the view immediately while live data loads.
    /// Ignores anything that isn't a valid aircraft address (links and notifications carry remote data).
    static func show(hex: String, snapshot: Flight? = nil) {
        guard let hex = AircraftID.hex(hex) else {
            fdLog.error("Ignoring request to show an invalid aircraft address")
            return
        }
        if let presenter {
            presenter(hex, snapshot)
        } else {
            showInNewWindow(hex: hex, snapshot: snapshot)
        }
    }

    /// Shows the separate detail window for `hex`, creating it if needed. `snapshot` is ignored
    /// when the window already exists.
    static func showInNewWindow(hex: String, snapshot: Flight? = nil) {
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

/// The aircraft a detail window is showing, with Back/Forward history. Clicking another plane
/// on the map switches it in place.
@MainActor
final class FlightDetailNavigator: ObservableObject {
    @Published private(set) var model: FlightDetailModel
    @Published private(set) var backStack: [Flight] = []
    @Published private(set) var forwardStack: [Flight] = []
    var onSwitch: ((FlightDetailModel) -> Void)?
    private static let historyLimit = 30

    init(hex: String, snapshot: Flight?) {
        model = FlightDetailModel(hex: hex, snapshot: snapshot)
    }

    func select(_ flight: Flight) {
        guard flight.id.lowercased() != model.hex else { return }
        if let current = model.flight {
            backStack.append(current)
            if backStack.count > Self.historyLimit { backStack.removeFirst() }
        }
        forwardStack.removeAll()
        show(flight)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current = model.flight { forwardStack.append(current) }
        show(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = model.flight { backStack.append(current) }
        show(next)
    }

    private func show(_ flight: Flight) {
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
        // No `.id`: the map persists and glides to the new aircraft; the sidebar crossfades.
        FlightDetailView(model: navigator.model)
            .environment(\.openFlightDetail) { navigator.select($0) }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button(action: navigator.goBack) { Label("Back", systemImage: "chevron.backward") }
                        .help(navigator.backStack.last.map { "Back to \($0.displayNumber)" } ?? "Back")
                        .keyboardShortcut("[", modifiers: .command)
                        .disabled(navigator.backStack.isEmpty)
                    Button(action: navigator.goForward) { Label("Forward", systemImage: "chevron.forward") }
                        .help(navigator.forwardStack.last.map { "Forward to \($0.displayNumber)" } ?? "Forward")
                        .keyboardShortcut("]", modifiers: .command)
                        .disabled(navigator.forwardStack.isEmpty)
                }
            }
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 620, height: 420)
        let host = NSHostingController(rootView: FlightDetailRoot(navigator: navigator))
        // Bridge the Back/Forward toolbar items into the window; the title is set below.
        host.sceneBridgingOptions = [.toolbars]
        window.contentViewController = host
        window.setContentSize(NSSize(width: 920, height: 640))
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
            .map { (FlightDetailModel.title(for: $0, hex: hex), FlightDetailModel.subtitle(for: $0)) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak window] title, subtitle in
                window?.title = title
                window?.subtitle = subtitle
            }
    }

    func windowWillClose(_ notification: Notification) {
        navigator.model.stop()
        titleSubscription = nil
        onClose?()
    }
}
