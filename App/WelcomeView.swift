import SwiftUI

/// First-run welcome: sets the location, explains the widget and offers alerts.
struct WelcomeView: View {
    @ObservedObject var store: LiveStore
    var onSetUpAlerts: () -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 22) {
                WelcomeStep(symbol: "location.fill", tint: .blue, title: "Where are you?",
                            detail: "FlightDesk shows aircraft within your search radius.") {
                    VStack(alignment: .leading, spacing: 8) {
                        if !store.placeName.isEmpty {
                            Label(store.placeName, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.body.weight(.medium))
                                .transition(.opacity)
                        }
                        LocationSearch(store: store)
                    }
                }
                WelcomeStep(symbol: "square.grid.2x2.fill", tint: .orange, title: "Add the widget",
                            detail: "Right-click an empty spot on the desktop, choose Edit Widgets…, then search for FlightDesk.")
                WelcomeStep(symbol: "bell.badge.fill", tint: .red, title: "Get alerts",
                            detail: "Emergency squawks, military aircraft and the tail numbers on your watchlist.") {
                    Button("Set Up Alerts…", action: onSetUpAlerts)
                }
                WelcomeStep(symbol: "menubar.rectangle", tint: .purple, title: "Always in the menu bar",
                            detail: "Close this window anytime. FlightDesk keeps your widgets and alerts up to date from the menu bar.")
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 24)

            Divider()
            HStack {
                Text("You can change all of this later in Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Get Started", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 540)
        .animation(.easeInOut(duration: 0.2), value: store.placeName)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Welcome to FlightDesk")
                .font(.largeTitle.weight(.bold))
            Text("See what’s flying overhead — on your desktop, in the menu bar and on a live radar.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 36)
        .padding(.top, 40)
    }
}

private struct WelcomeStep<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                accessory.padding(.top, 4)
            }
        }
    }
}

private extension WelcomeStep where Accessory == EmptyView {
    init(symbol: String, tint: Color, title: String, detail: String) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail) { EmptyView() }
    }
}
