// Lock Screen widget faces for the nearest flight. Compiled into the widget extension and (for the
// DEBUG snapshot renders) the app.

import SwiftUI
import WidgetKit

/// What a Lock Screen widget shows: the nearest flight, or why there isn't one.
struct NearestFlightState {
    var flight: Flight?
    var units: UnitSystem
    /// Shown when there's no flight ("No location", "Quiet skies", "Offline").
    var status: String

    static let sample = NearestFlightState(flight: PanelModel.sample.flights.first, units: .imperial, status: "")
}

/// Circular: the distance large in the middle, the altitude beneath, a small plane on top.
struct NearestCircularView: View {
    let state: NearestFlightState

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let f = state.flight {
                VStack(spacing: -1) {
                    Image(systemName: AircraftClass(typeCode: f.typeCode).symbol)
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(AircraftClass(typeCode: f.typeCode) == .rotorcraft ? 0 : -45))
                    Text(NearestFlightText.distanceValue(f.distance, units: state.units))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                        .monospacedDigit()
                    Text(NearestFlightText.shortAltitude(f.altitude, units: state.units))
                        .font(.system(size: 9, weight: .semibold))
                        .minimumScaleFactor(0.6)
                }
                .padding(4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Nearest flight \(f.displayNumber), \(FlightRowText.accessibilityValue(f, units: state.units))")
            } else {
                Image(systemName: "airplane")
                    .font(.system(size: 18, weight: .semibold))
                    .accessibilityLabel(state.status)
            }
        }
        .widgetAccentable()
    }
}

/// Rectangular: flight number, route (or operator), then distance, direction and altitude.
struct NearestRectangularView: View {
    let state: NearestFlightState

    var body: some View {
        if let f = state.flight {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: AircraftClass(typeCode: f.typeCode).symbol)
                        .font(.system(size: 11, weight: .bold))
                        .rotationEffect(.degrees(AircraftClass(typeCode: f.typeCode) == .rotorcraft ? 0 : -45))
                    Text(f.displayNumber).font(.headline).lineLimit(1)
                }
                .widgetAccentable()
                Text(NearestFlightText.detail(f)).font(.subheadline).lineLimit(1)
                Text(NearestFlightText.position(f, units: state.units))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Label("FlightDesk", systemImage: "airplane").font(.headline).widgetAccentable()
                Text(state.status).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Inline, beside the date: "✈︎ DL1342 MKE→ORD 4.2 nm".
struct NearestInlineView: View {
    let state: NearestFlightState

    var body: some View {
        if let f = state.flight {
            Label(NearestFlightText.inline(f, units: state.units), systemImage: "airplane")
        } else {
            Label(state.status, systemImage: "airplane")
        }
    }
}
