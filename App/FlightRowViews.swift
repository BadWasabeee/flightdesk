// List rows, badges, chips and map markers for nearby aircraft. Shared by the Mac main window and
// the iPhone radar, so both draw flights the same way.

import SwiftUI

struct FlightRow: View {
    let f: Flight
    let phase: RunwayPhase?
    /// The spotting log had never seen this aircraft's type before.
    var firstSighting = false
    @Environment(\.displayOptions) private var o

    /// The second line: the runway phase (tinted) ahead of the route, or the usual subtitle.
    private var subtitle: Text {
        guard let p = FlightRowText.phaseSubtitle(f, phase: phase, options: o) else { return Text(FlightRowText.subtitle(f)) }
        let tag = Text(p.tag).foregroundStyle(phase?.isCaution == true ? Color.orange : Color.accentColor)
        return p.rest.isEmpty ? tag : tag + Text(" · \(p.rest)")
    }

    var body: some View {
        HStack(spacing: 10) {
            FlightBadge(f: f, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(f.displayNumber).font(.headline).lineLimit(1)
                    if let s = f.situation { SituationChip(situation: s) } else if firstSighting { FirstSightingChip() }
                }
                subtitle
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 3) {
                    Text(o.altitude(f.altitude))
                    ClimbGlyph(state: ClimbState(verticalRate: f.verticalRate))
                }
                Text("\(o.distance(f.distance)) \(f.direction)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, ClimbGlyph.width + 3)
            }
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FlightRowText.accessibilityLabel(f))
        .accessibilityValue([FlightRowText.accessibilityValue(f, units: o.units), phase?.tag(o), firstSighting ? "first sighting of this type" : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAction(named: "Open Details") { FlightDetail.show(hex: f.id, snapshot: f) }
    }
}

/// Climb/descent arrow in a fixed-width slot, so altitudes line up whether or not one is shown.
struct ClimbGlyph: View {
    static let width: CGFloat = 9
    let state: ClimbState

    var body: some View {
        Group {
            switch state {
            case .climbing: Image(systemName: "arrow.up")
            case .descending: Image(systemName: "arrow.down")
            case .level: Color.clear
            }
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .frame(width: Self.width)
        .accessibilityHidden(true)
    }
}

/// A compact situation label for a list row: "⚠ EMERGENCY", "◆ DIVERT MKE" in a red or orange capsule.
/// The row's accessibility label already speaks it.
struct SituationChip: View {
    let situation: FlightSituation
    var body: some View {
        Label(situation.tag, systemImage: situation.symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(situation.tint))
            .fixedSize()
            .help(situation.spoken)
            .accessibilityHidden(true)
    }
}

/// "First sighting": a type the spotting log had never seen. The row's accessibility value speaks it.
struct FirstSightingChip: View {
    var body: some View {
        Text("First sighting")
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().strokeBorder(Color.accentColor, lineWidth: 1))
            .fixedSize()
            .help("The first time your logbook has seen this aircraft type")
            .accessibilityHidden(true)
    }
}

/// The airline logo, or a neutral disc with the aircraft's class symbol, always the same size so
/// rows line up.
struct FlightBadge: View {
    let f: Flight
    let size: CGFloat
    @Environment(\.displayOptions) private var o
    @Environment(\.colorScheme) private var scheme

    /// True when the cached logo reads well at badge size (not a wide wordmark, not too dark).
    private func isLegible(_ logo: LogoStore.Logo) -> Bool {
        if case .logo = FlightMarkKind.resolve(f, logo: logo.url, logoSize: logo.size, brightness: logo.brightness,
                                               darkBackground: scheme == .dark) { return true }
        return false
    }

    var body: some View {
        Group {
            if o.showLogos, let logo = LogoStore.logo(for: f.logoKey?.id) {
                if isLegible(logo) {
                    Image(platformImage: logo.image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    // Wordmarks and dark logos become the shared airline-code tile.
                    FlightMark(flight: f, size: size)
                }
            } else {
                let kind = AircraftClass(typeCode: f.typeCode)
                Circle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: kind.symbol)
                            .font(.system(size: size * 0.42 * min(1.15, kind.iconScale + 0.15), weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(kind == .rotorcraft ? 0 : -45))
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Map

/// An aircraft on the radar map: its class symbol rotated to its track, optionally labelled with
/// its flight number. The icon is always centred on the aircraft's position.
struct AircraftMarker: View {
    let f: Flight
    let selected: Bool
    let showsLabel: Bool
    @Environment(\.displayOptions) private var o

    private static let labelHeight: CGFloat = 14
    private var halo: Color { Color.platformBackground }

    var body: some View {
        VStack(spacing: 0) {
            // Mirrors the label so the icon stays at the annotation's centre.
            if showsLabel { Color.clear.frame(height: Self.labelHeight) }
            icon
            if showsLabel { label.frame(height: Self.labelHeight) }
        }
        .fixedSize()
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FlightRowText.accessibilityLabel(f))
        .accessibilityValue(FlightRowText.accessibilityValue(f, units: o.units))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var kind: AircraftClass { AircraftClass(typeCode: f.typeCode) }
    /// Red for emergencies, orange for diversions and returns; nil for ordinary flights.
    private var alertTint: Color? { f.situation?.tint }

    /// The symbol points east; the map is always north-up.
    private var rotation: Angle { .degrees(kind == .rotorcraft ? 0 : (f.track ?? 90) - 90) }

    @ViewBuilder
    private var icon: some View {
        if selected {
            Image(systemName: kind.symbol)
                .font(.system(size: min(20, 16 * kind.iconScale), weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(rotation)
                .frame(width: 32, height: 32)
                .background(Circle().fill(alertTint ?? Color.accentColor))
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .contentShape(Circle())
        } else {
            Image(systemName: kind.symbol)
                .font(.system(size: 15 * kind.iconScale, weight: alertTint == nil ? .semibold : .heavy))
                .foregroundStyle(alertTint ?? (f.looksLikeAirline ? Color.primary : Color.primary.opacity(0.7)))
                .rotationEffect(rotation)
                .shadow(color: halo, radius: 1)
                .shadow(color: halo, radius: 1)
                .frame(width: 26, height: 26)
                // A ring makes unusual flights stand out among dozens of icons.
                .background { if let alertTint { Circle().strokeBorder(alertTint, lineWidth: 1.5).padding(1) } }
                .contentShape(Circle())
        }
    }

    @ViewBuilder
    private var label: some View {
        if selected {
            Text(f.displayNumber)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .background(Capsule().fill(alertTint ?? Color.accentColor))
                .contentShape(Rectangle())
        } else {
            Text(f.displayNumber)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(alertTint ?? Color.primary)
                .shadow(color: halo, radius: 1)
                .shadow(color: halo, radius: 1)
                .contentShape(Rectangle())
        }
    }

    private var helpText: String {
        let detail = [f.situation?.title ?? "", FlightRowText.subtitle(f), o.altitude(f.altitude)]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return "\(f.displayNumber) — \(detail)\nDouble-click for details"
    }
}

/// A capsule at the top of the map for loading, offline and empty states.
struct MapStatusBanner: View {
    let feed: RadarFeedState
    let hasFlights: Bool
    let radius: String

    var body: some View {
        Group {
            switch feed {
            case .loading where !hasFlights:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Looking for aircraft…")
                }
            case .offline:
                Label(hasFlights ? "Can’t reach flight data · positions are estimated" : "Can’t reach flight data · retrying",
                      systemImage: "wifi.exclamationmark")
            case .empty:
                Label("No aircraft within \(radius) right now", systemImage: "airplane")
            default:
                EmptyView()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            if feed != .live && !(feed == .loading && hasFlights) && feed != .noLocation {
                Capsule().fill(.regularMaterial).shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
