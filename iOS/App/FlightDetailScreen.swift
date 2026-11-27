// One aircraft's detail, pushed in the Radar tab's sheet. The cards are the Mac detail's sidebar
// (App/FlightDetailView.swift); the full-screen map behind the sheet draws its track and route.

import SwiftUI

struct FlightDetailScreen: View {
    @ObservedObject var radar: RadarModel
    let hex: String

    var body: some View {
        Group {
            if let model = radar.detail, model.hex == hex {
                DetailCards(model: model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DetailCards: View {
    @ObservedObject var model: FlightDetailModel
    private let router = AppRouter.shared

    var body: some View {
        FlightDetailSidebar(model: model)
            .environment(\.displayOptions, model.display)
            .scrollContentBackground(.hidden)
            // The cards' header carries the flight number; a title would repeat it.
            .navigationTitle("")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { router.mapCommands.send(.aircraft) } label: {
                        Label("Center on Aircraft", systemImage: "scope")
                    }
                    .disabled(model.flight == nil)
                    Button { router.mapCommands.send(.wholeFlight) } label: {
                        Label("Show Whole Flight", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    .disabled(model.flight == nil)
                }
            }
    }
}
