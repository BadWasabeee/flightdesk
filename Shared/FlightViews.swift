// Flight-board views shared by the desktop widget and the app's live panel / preview.
// Two looks: a glowing LED board, and a Standard system look that follows Light/Dark Mode.

import SwiftUI
import AppKit
import WidgetKit

extension LEDTheme {
    var color: Color {
        switch self {
        case .amber: Color(red: 1.00, green: 0.70, blue: 0.08)
        case .green: Color(red: 0.30, green: 1.00, blue: 0.40)
        case .red: Color(red: 1.00, green: 0.27, blue: 0.20)
        case .blue: Color(red: 0.38, green: 0.62, blue: 1.00)
        case .cyan: Color(red: 0.25, green: 0.95, blue: 1.00)
        case .white: Color(white: 0.94)
        }
    }
}

private struct DisplayOptionsKey: EnvironmentKey { static let defaultValue = DisplayOptions() }
extension EnvironmentValues {
    var displayOptions: DisplayOptions {
        get { self[DisplayOptionsKey.self] }
        set { self[DisplayOptionsKey.self] = newValue }
    }
}

enum PanelLayout { case small, medium, large, extraLarge, panel }

extension DisplayOptions {
    /// Hairline separators.
    var ruleColor: Color { isStandard ? Color.primary.opacity(0.15) : theme.color.opacity(0.18) }
    var glowEnabled: Bool { glow && !isStandard }
}

// MARK: - Primitives

struct LEDText: View {
    let text: String
    let size: CGFloat
    var dim = false
    var weight: Font.Weight = .bold
    var lines = 1
    /// Accent text (route codes) is drawn at full strength.
    var accent = false
    @Environment(\.displayOptions) private var o

    init(_ text: String, _ size: CGFloat, dim: Bool = false, weight: Font.Weight = .bold, lines: Int = 1, accent: Bool = false) {
        self.text = text; self.size = size; self.dim = dim; self.weight = weight; self.lines = lines; self.accent = accent
    }

    private var color: Color {
        // Standard: system label colors, so it follows Light and Dark Mode.
        if o.isStandard { return dim ? Color.secondary : Color.primary }
        return dim ? o.theme.color.opacity(0.5) : o.theme.color
    }

    /// System widgets use lighter weights than the LED board.
    private var standardWeight: Font.Weight {
        switch weight { case .heavy, .black, .bold: .semibold; case .semibold: .medium; default: weight }
    }

    var body: some View {
        let c = color
        Text(o.isStandard ? text : text.uppercased())
            .font(.system(size: size, weight: o.isStandard ? standardWeight : weight, design: o.isStandard ? .default : .monospaced))
            .monospacedDigit()
            .foregroundStyle(c)
            .shadow(color: o.glowEnabled ? c.opacity(0.65) : .clear, radius: size / 6)
            .lineLimit(lines)
            .minimumScaleFactor(0.55)
            .widgetAccentable(!dim)
    }
}

struct DotMatrix: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var y: CGFloat = 1
            while y < size.height {
                var x: CGFloat = 1
                while x < size.width { path.addEllipse(in: CGRect(x: x, y: y, width: 1.4, height: 1.4)); x += 4 }
                y += 4
            }
            ctx.fill(path, with: .color(.white.opacity(0.045)))
        }
    }
}

/// The dark LED board (used for the LED style).
struct PanelBackground: View {
    @Environment(\.displayOptions) private var o
    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.035, blue: 0.03)
            if o.dotMatrix { DotMatrix() }
        }
    }
}

/// Window chrome for the floating panel and the settings preview.
struct PanelChrome: ViewModifier {
    let options: DisplayOptions
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if options.isStandard {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.1), lineWidth: 1))
        } else {
            content
                .background(PanelBackground().environment(\.displayOptions, options))
                .clipShape(shape)
                .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
    }
}

/// Origin → destination line. With `progress` the plane sits at the aircraft's live position:
/// the flown part is solid, the part still to fly is faint.
struct RouteLine: View {
    var iconSize: CGFloat = 16
    var progress: Double? = nil
    @Environment(\.displayOptions) private var o
    private var line: Color { o.isStandard ? Color.secondary.opacity(0.5) : o.theme.color.opacity(0.45) }
    private var flown: Color { o.isStandard ? Color.primary.opacity(0.75) : o.theme.color.opacity(0.85) }
    private var ahead: Color { o.isStandard ? Color.secondary.opacity(0.3) : o.theme.color.opacity(0.22) }
    private var icon: Color { o.isStandard ? .primary : o.theme.color }

    var body: some View {
        if let p = progress {
            GeometryReader { geo in
                let h = max(1, iconSize / 8), w = geo.size.width
                let x = iconSize / 2 + (w - iconSize) * p
                ZStack(alignment: .leading) {
                    Capsule().fill(ahead).frame(height: h)
                    Capsule().fill(flown).frame(width: max(0, x), height: h)
                    plane.position(x: x, y: geo.size.height / 2)
                }
                .frame(height: geo.size.height)
            }
            .frame(height: iconSize * 1.3)
            .accessibilityLabel("\(Int((p * 100).rounded())) percent of the way")
        } else {
            HStack(spacing: 4) {
                Rectangle().fill(line).frame(height: max(1, iconSize / 8))
                plane
                Rectangle().fill(line).frame(height: max(1, iconSize / 8))
            }
        }
    }

    private var plane: some View {
        Image(systemName: "airplane")
            .font(.system(size: iconSize, weight: .bold))
            .foregroundStyle(icon)
            .shadow(color: o.glowEnabled ? o.theme.color.opacity(0.6) : .clear, radius: 3)
            .widgetAccentable()
    }
}

/// Airline logo from the shared cache. Draws nothing until the logo has been downloaded.
struct AirlineLogo: View {
    let code: String?
    var size: CGFloat
    /// Keep the space even without a logo, so list columns stay aligned.
    var reserve = false
    @Environment(\.displayOptions) private var o

    var body: some View {
        if o.showLogos, let u = AirlineLogos.file(for: code), let img = NSImage(contentsOf: u) {
            logo(Image(nsImage: img).resizable().interpolation(.high))
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else if reserve && o.showLogos {
            Color.clear.frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func logo(_ i: Image) -> some View {
        if #available(macOS 15.0, *) {
            i.widgetAccentedRenderingMode(.fullColor)
        } else {
            i
        }
    }
}

// MARK: - Featured flight

struct FeaturedView: View {
    let f: Flight
    let layout: PanelLayout
    @Environment(\.displayOptions) private var o

    private var codeSize: CGFloat {
        switch layout { case .small: 24; case .extraLarge: 46; default: 38 }
    }

    var body: some View {
        Group { if layout == .small { small } else { regular } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = [f.airlineName, f.displayNumber]
        if let r = f.route { parts.append("from \(r.from.city.isEmpty ? r.from.code : r.from.city) to \(r.to.city.isEmpty ? r.to.code : r.to.city)") }
        parts.append(f.aircraft?.model ?? f.typeCode)
        parts.append("altitude \(o.altitude(f.altitude)), \(o.distance(f.distance)) \(f.direction)")
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var subtitle: String {
        f.looksLikeAirline ? "Route not verified" : "Private · \(f.reg)"
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                AirlineLogo(code: f.airlineCode, size: 12)
                LEDText(f.airlineName.isEmpty ? f.typeCode : f.airlineName, 9, dim: true)
                Spacer(minLength: 2)
                LEDText(f.displayNumber, 10)
            }
            if let r = f.route {
                HStack(spacing: 5) {
                    LEDText(r.from.code, codeSize, accent: true)
                    RouteLine(iconSize: 11, progress: f.progress)
                    LEDText(r.to.code, codeSize, accent: true)
                }
                if o.showCities {
                    HStack(spacing: 4) {
                        LEDText(r.from.city, 8, dim: true, weight: .semibold)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LEDText(r.to.city, 8, dim: true, weight: .semibold)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } else {
                LEDText(f.callsign.isEmpty ? f.reg : f.callsign, codeSize, accent: true)
                LEDText(subtitle, 8, dim: true, weight: .semibold)
            }
            Spacer(minLength: 0)
            LEDText((f.aircraft?.model ?? f.typeCode), 9)
            HStack {
                LEDText(f.climbSymbol + o.altitude(f.altitude), 10)
                Spacer(minLength: 2)
                LEDText(o.distance(f.distance) + " " + f.direction, 10)
            }
        }
    }

    private var regular: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AirlineLogo(code: f.airlineCode, size: layout == .medium ? 13 : 16)
                LEDText(f.airlineName.isEmpty ? "—" : f.airlineName, 13, dim: true)
                Spacer()
                LEDText(f.displayNumber, 13)
            }
            if let r = f.route {
                HStack(spacing: 10) {
                    LEDText(r.from.code, codeSize, accent: true).fixedSize()
                    RouteLine(progress: f.progress)
                    LEDText(r.to.code, codeSize, accent: true).fixedSize()
                }
                if o.showCities {
                    HStack {
                        LEDText(r.from.city, 11, dim: true, weight: .semibold)
                        Spacer()
                        LEDText(r.to.city, 11, dim: true, weight: .semibold)
                    }
                }
            } else {
                LEDText(f.callsign.isEmpty ? f.reg : f.callsign, codeSize, accent: true)
                if o.showCities { LEDText(subtitle, 11, dim: true, weight: .semibold) }
            }
            HStack(spacing: 12) {
                LEDText((f.aircraft?.model ?? f.typeCode), 12)
                Spacer(minLength: 4)
                LEDText(f.climbSymbol + o.altitude(f.altitude), 12).fixedSize()
                LEDText(o.speed(f.speed), 12).fixedSize()
                LEDText(o.distance(f.distance) + " " + f.direction, 12).fixedSize()
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - List rows

struct RowView: View {
    let f: Flight
    var wide = false
    @Environment(\.displayOptions) private var o

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                AirlineLogo(code: f.airlineCode, size: 12, reserve: true)
                LEDText(f.displayNumber, 11)
            }
            .frame(width: o.showLogos ? 76 : 62, alignment: .leading)
            LEDText(f.route.map { "\($0.from.code)›\($0.to.code)" } ?? "—", 11, dim: true)
                .frame(width: o.showLogos ? 60 : 66, alignment: .leading)
            LEDText(wide ? (f.aircraft?.model ?? f.typeCode) : f.typeCode, 11, dim: true)
                .frame(maxWidth: wide ? .infinity : 40, alignment: .leading)
                .layoutPriority(wide ? 1 : 0)
            if !wide { Spacer(minLength: 0) }
            LEDText(o.altitude(f.altitude), 11, dim: true).frame(width: o.showLogos ? 64 : 70, alignment: .trailing)
            LEDText(o.distance(f.distance), 11).frame(width: 56, alignment: .trailing)
        }
    }
}

// MARK: - Whole panel

struct PanelContent: View {
    let model: PanelModel
    let layout: PanelLayout
    var accessory: AnyView? = nil
    @Environment(\.displayOptions) private var o

    private var rowCount: Int {
        guard o.showList else { return 0 }
        switch layout { case .small, .medium: return 0; case .panel: return 4; case .large: return 7; case .extraLarge: return 10 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: layout == .small ? 6 : 10) {
            if o.showHeader || accessory != nil { header }
            if layout == .extraLarge {
                HStack(alignment: .top, spacing: 18) {
                    featured.frame(width: 360)
                    if rowCount > 0 {
                        Rectangle().fill(o.ruleColor).frame(width: 1)
                        rows(wide: false).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                featured
                if rowCount > 0 {
                    Rectangle().fill(o.ruleColor).frame(height: 1)
                    rows(wide: false)
                        .frame(height: layout == .panel ? CGFloat(rowCount) * 19 : nil, alignment: .top)
                }
            }
            if layout != .panel { Spacer(minLength: 0) }
        }
        .padding(layout == .small ? 12 : 16)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if o.showHeader {
                LEDText("✈ " + (model.placeName.isEmpty ? "Overhead" : model.placeName), 10, dim: true)
                Spacer(minLength: 4)
                if layout != .small {
                    LEDText("\(model.flights.count) in \(o.radius(model.radiusNM))", 10, dim: true).fixedSize()
                }
                if let u = model.updated, layout != .panel {
                    LEDText(u.formatted(date: .omitted, time: .shortened), 10, dim: true).fixedSize()
                }
            } else {
                Spacer()
            }
            if let accessory { accessory }
        }
    }

    @ViewBuilder private var featured: some View {
        if let f = model.featured {
            FeaturedView(f: f, layout: layout).id(f.id).transition(.opacity)
                .frame(height: layout == .panel ? 118 : nil, alignment: .top)
        } else {
            LEDText((model.status.isEmpty ? "Loading…" : model.status),
                    layout == .small ? 10 : 12, lines: 3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: layout == .small ? 90 : 110)
        }
    }

    private func rows(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.others.prefix(rowCount)) { RowView(f: $0, wide: wide) }
        }
    }
}
