// The radar map fills the screen; a sheet that never closes holds the tabs (Radar, Logbook,
// Settings), like Find My. Dragging it down shows more map; the map stays interactive above it.

import SwiftUI

struct RootView: View {
    @ObservedObject var store: LiveStore
    @ObservedObject var radar: RadarModel
    @ObservedObject private var router = AppRouter.shared

    var body: some View {
        RadarMapView(store: store, radar: radar)
            .sheet(isPresented: .constant(true)) {
                SheetTabs(store: store, radar: radar)
                    .presentationDetents(AppRouter.detents, selection: $router.detent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled()
                    .presentationContentInteraction(.scrolls)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { router.sheetHeight = $0 }
            }
    }
}

/// The sheet's content: one navigation stack per tab.
private struct SheetTabs: View {
    @ObservedObject var store: LiveStore
    @ObservedObject var radar: RadarModel
    @ObservedObject private var router = AppRouter.shared

    var body: some View {
        TabView(selection: $router.tab) {
            NavigationStack(path: detailPath) {
                FlightListScreen(store: store, radar: radar)
                    .navigationDestination(for: String.self) { hex in
                        FlightDetailScreen(radar: radar, hex: hex)
                    }
            }
            .tabItem { Label("Radar", systemImage: "dot.radiowaves.left.and.right") }
            .tag(AppRouter.TabID.radar)

            NavigationStack {
                LogbookScreen(radar: radar)
            }
            .tabItem { Label("Logbook", systemImage: "book") }
            .tag(AppRouter.TabID.logbook)

            NavigationStack(path: $router.settingsPath) {
                SettingsScreen(store: store)
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(AppRouter.TabID.settings)
        }
        .environment(\.displayOptions, store.settings.display.withStandardStyle)
    }

    /// The radar stack shows at most one detail: the radar's. Back closes it and clears the selection.
    private var detailPath: Binding<[String]> {
        Binding(
            get: { radar.detail.map { [$0.hex] } ?? [] },
            set: { path in
                if let hex = path.last {
                    if radar.detail?.hex != hex { router.showFlight(hex: hex) }
                } else {
                    router.closeDetail()
                }
            })
    }
}
