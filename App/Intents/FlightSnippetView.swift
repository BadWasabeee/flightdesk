// The card Siri and Shortcuts show with "What's Flying Overhead" and "Nearby Flights".

import SwiftUI

struct FlightsSnippetView: View {
    let flights: [FlightEntity]
    /// "Near Denver", or empty.
    let place: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !place.isEmpty {
                Text("Near \(place)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if flights.isEmpty {
                Label("Quiet skies", systemImage: "cloud.sun")
                    .foregroundStyle(.secondary)
            }
            ForEach(flights, id: \.id) { f in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: AircraftClass(typeCode: f.typeCode).symbol)
                        .foregroundStyle(.orange)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(f.title).font(.headline.monospacedDigit())
                            if let airline = f.airline { Text(airline).foregroundStyle(.secondary) }
                        }
                        Text(f.subtitle)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(f.situation == nil ? Color.secondary : Color.orange)
                            .lineLimit(2)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(f.summary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
