// Flight-board views shared by the desktop widget and the app's live panel / preview.
// Two looks: a glowing LED board, and a Standard system look that follows Light/Dark Mode.

import SwiftUI
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

/// How flights in a `PanelContent` respond to clicks.
enum FlightLinkStyle {
    /// Not clickable (settings preview, snapshots).
    case none
    /// Widget: each flight is a `Link` to its `FlightLink` deep link.
    case link
    /// In-app: run the action directly.
    case action(@MainActor (Flight) -> Void)
}

private struct FlightLinkStyleKey: EnvironmentKey { static let defaultValue = FlightLinkStyle.none }
extension EnvironmentValues {
    var flightLinkStyle: FlightLinkStyle {
        get { self[FlightLinkStyleKey.self] }
        set { self[FlightLinkStyleKey.self] = newValue }
    }
}

/// Makes a featured flight or list row clickable according to `\.flightLinkStyle`.
private struct FlightTarget: ViewModifier {
    let flight: Flight
    @Environment(\.flightLinkStyle) private var style

    func body(content: Content) -> some View {
        switch style {
        case .none:
            content
        case .link:
            if let url = FlightLink.url(for: flight.id) {
                Link(destination: url) { content.contentShape(Rectangle()) }
            } else {
                content
            }
        case .action(let action):
            HoverTarget(content: content) { action(flight) }
        }
    }
}

/// In-app click target with a hover highlight, so the floating panel reads as interactive.
private struct HoverTarget<Content: View>: View {
    let content: Content
    let action: @MainActor () -> Void
    @State private var hovering = false
    @Environment(\.displayOptions) private var o

    var body: some View {
        content
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(o.isStandard ? Color.primary.opacity(0.07) : o.theme.color.opacity(0.09))
                    .padding(.horizontal, -6).padding(.vertical, -3)
                    .opacity(hovering ? 1 : 0)
            )
            .onHover { inside in
                guard inside != hovering else { return }
                withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
                #if os(macOS)
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                #endif
            }
            .onDisappear {
                #if os(macOS)
                if hovering { NSCursor.pop() }
                #endif
                hovering = false
            }
            .onTapGesture { action() }
            .help("Show flight details")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

extension DisplayOptions {
    /// Hairline separators.
    var ruleColor: Color { isStandard ? Color.primary.opacity(0.12) : theme.color.opacity(0.16) }
    var glowEnabled: Bool { glow && !isStandard }
    /// Secondary text / glyph color.
    var dimColor: Color { isStandard ? Color.secondary : theme.color.opacity(0.5) }
}

// MARK: - Layout metrics

/// Type sizes and spacing per widget family. One place to tune the grid.
struct PanelMetrics: Equatable {
    let layout: PanelLayout

    var padding: CGFloat { layout == .small ? 14 : 16 }
    var sectionSpacing: CGFloat { layout == .small ? 7 : 10 }
    var headerSize: CGFloat { layout == .small ? 9.5 : 10 }
    var headerHeight: CGFloat { 13 }

    /// Featured route codes (SEA → JFK): the one thing to read from across the room.
    var codeSize: CGFloat {
        switch layout {
        case .small: 26
        case .medium: 38
        case .large, .panel: 40
        case .extraLarge: 56
        }
    }
    /// Featured codes when the list is hidden and the flight gets the whole widget.
    var heroCodeSize: CGFloat { layout == .extraLarge ? 72 : 54 }
    var identitySize: CGFloat { layout == .small ? 9.5 : (layout == .extraLarge ? 14 : 13) }
    var citySize: CGFloat { layout == .small ? 8.5 : (layout == .extraLarge ? 12 : 11) }
    var statValueSize: CGFloat { layout == .extraLarge ? 17 : 14 }
    var statLabelSize: CGFloat { 8.5 }

    var rowFont: CGFloat { layout == .extraLarge ? 12 : 11 }
    var rowHeight: CGFloat { rowFont + 5 }
    var rowSpacing: CGFloat { 5 }
    var rowMarkSize: CGFloat { rowFont + 4 }
    var footerHeight: CGFloat { 12 }
    /// XL has room for board-style column headings over the list.
    var showsColumnHeader: Bool { layout == .extraLarge }
    var columnHeaderHeight: CGFloat { 11 }

    /// Families that show the "others" list (when `showList` is on).
    var supportsList: Bool { layout == .large || layout == .extraLarge || layout == .panel }
    /// The live panel always has the same height, so it doesn't jump as flights come and go.
    var fixedRowCount: Int? { layout == .panel ? 4 : nil }
    /// Large and XL put the aircraft count in a footer under the list; others show it in the header.
    var showsFooter: Bool { layout == .large || layout == .extraLarge }

    enum Stats { case compact, inline, grid, fullGrid }
    var stats: Stats {
        switch layout {
        case .small: .compact
        case .medium: .inline
        case .large, .panel: .grid
        case .extraLarge: .fullGrid
        }
    }

    /// How many list rows fit in `height` points.
    func rowsThatFit(_ height: CGFloat) -> Int {
        guard height >= rowHeight else { return 0 }
        return Int((height + rowSpacing) / (rowHeight + rowSpacing))
    }

    /// Height of `count` list rows.
    func rowsHeight(_ count: Int) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * rowHeight + CGFloat(count - 1) * rowSpacing
    }
}

// MARK: - Formatting helpers (board-specific; the shared formatters live in FlightCore)

enum BoardFormat {
    /// "+1,800FPM" / "+1,800 fpm", "+9.1M/S" / "+9.1 m/s"; "LEVEL" in cruise.
    static func verticalSpeed(_ fpm: Double, _ o: DisplayOptions) -> String {
        guard abs(fpm) > 300 else { return o.isStandard ? "Level" : "LEVEL" }
        let sign = fpm > 0 ? "+" : "−"
        if o.units == .metric {
            let v = String(format: "%.1f", abs(fpm) * 0.00508)
            return o.isStandard ? "\(sign)\(v) m/s" : "\(sign)\(v)M/S"
        }
        let v = (Int(abs(fpm) / 100) * 100).formatted()
        return o.isStandard ? "\(sign)\(v) fpm" : "\(sign)\(v)FPM"
    }

    /// Long distances without the decimal: "1,104NM" / "1,104 nm".
    static func longDistance(_ nm: Double, _ o: DisplayOptions) -> String {
        guard nm >= 100 else { return o.distance(nm) }
        let metric = o.units == .metric
        let v = Int((metric ? nm * 1.852 : nm).rounded()).formatted()
        let u = metric ? (o.isStandard ? "km" : "KM") : (o.isStandard ? "nm" : "NM")
        return o.isStandard ? "\(v) \(u)" : v + u
    }

    /// Track over the ground: "095°".
    static func track(_ deg: Double?) -> String {
        guard let deg else { return "—" }
        return String(format: "%03d°", Int(deg.rounded()) % 360)
    }

    /// "SEA›JFK" for a list row; "ORD›MKE" while diverting to MKE, "RTN›ORD" while returning.
    static func route(_ f: Flight) -> String {
        guard let r = f.route else { return "—" }
        if case .returning(let origin)? = f.pathSituation { return "RTN›\(origin.code)" }
        return "\(r.from.code)›\((f.destination ?? r.to).code)"
    }

    /// Distance still to fly to where the aircraft is going, from the live position.
    static func toGo(_ f: Flight) -> Double? {
        guard f.route != nil, let to = f.destination else { return nil }
        return FlightService.gcDistance(f.lat, f.lon, to.lat, to.lon)
    }

    /// The airline name, or a sensible stand-in for flights without one.
    static func operatorName(_ f: Flight) -> String {
        if !f.airlineName.isEmpty { return f.airlineName }
        return f.looksLikeAirline ? (f.airlineICAO ?? "") : "General aviation"
    }

    /// A short accessibility description of a flight.
    static func spoken(_ f: Flight, _ o: DisplayOptions) -> String {
        var parts = [f.situation?.spoken ?? "", f.airlineName, f.displayNumber]
        if let r = f.route {
            parts.append("from \(r.from.city.isEmpty ? r.from.code : r.from.city) to \(r.to.city.isEmpty ? r.to.code : r.to.city)")
        }
        parts.append(f.aircraft?.model ?? f.typeCode)
        let climb = f.verticalRate > 300 ? ", climbing" : f.verticalRate < -300 ? ", descending" : ""
        parts.append("altitude \(o.altitude(f.altitude))\(climb)")
        parts.append("\(o.distance(f.distance)) \(f.direction)")
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
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
    /// A colour that overrides the style's own (situation highlights).
    var tint: Color? = nil
    /// Struck through (a scheduled destination the flight is no longer heading for).
    var struck = false
    @Environment(\.displayOptions) private var o

    init(_ text: String, _ size: CGFloat, dim: Bool = false, weight: Font.Weight = .bold, lines: Int = 1, accent: Bool = false,
         tint: Color? = nil, struck: Bool = false) {
        self.text = text; self.size = size; self.dim = dim; self.weight = weight; self.lines = lines; self.accent = accent
        self.tint = tint; self.struck = struck
    }

    private var color: Color {
        if let tint { return tint }
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
            .strikethrough(struck)
            .monospacedDigit()
            .foregroundStyle(c)
            // Dim text gets a softer bloom than lit text, like unlit vs. lit LED segments.
            .shadow(color: o.glowEnabled ? c.opacity(dim ? 0.35 : 0.6) : .clear, radius: max(1.5, size / 6))
            .lineLimit(lines)
            .minimumScaleFactor(0.6)
            // Numbers roll between timeline frames, like a flap board.
            .contentTransition(.numericText())
            .widgetAccentable(!dim)
    }
}

/// Small uppercase label above a value ("ALTITUDE").
private struct StatCell: View {
    let label: String
    let value: String
    let m: PanelMetrics
    var hero = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LEDText(label.uppercased(), m.statLabelSize + (hero ? 1 : 0), dim: true, weight: .semibold)
            LEDText(value, m.statValueSize + (hero ? 4 : 0))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
            // A faint wash of the LED color from the top, like light spilling off the lit segments.
            LinearGradient(colors: [o.theme.color.opacity(0.05), .clear], startPoint: .top, endPoint: .center)
            if o.dotMatrix { DotMatrix() }
        }
    }
}

/// Window chrome for the floating panel and the settings preview.
struct PanelChrome: ViewModifier {
    let options: DisplayOptions
    var cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if options.isStandard {
            content
                .background(Color.platformBackground, in: shape)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        } else {
            content
                .background(PanelBackground().environment(\.displayOptions, options))
                .clipShape(shape)
                // A bezel lit from above.
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.05)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 1))
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
/// Logos have transparent backgrounds, so they're drawn as-is, fitted into a `size` square.
struct AirlineLogo: View {
    /// `AirlineLogos.Key.id` (usually `Flight.logoKey?.id`).
    let code: String?
    var size: CGFloat
    /// Keep the space even without a logo, so list columns stay aligned.
    var reserve = false
    @Environment(\.displayOptions) private var o

    var body: some View {
        if o.showLogos, let logo = LogoStore.logo(for: code) {
            LogoImage(image: logo.image)
                .frame(width: size, height: size)
        } else if reserve && o.showLogos {
            Color.clear.frame(width: size, height: size)
        }
    }
}

/// A cached logo bitmap, kept in color but toned down in the Clear/Tinted desktop widget styles.
private struct LogoImage: View {
    let image: PlatformImage
    var body: some View {
        let i = Image(platformImage: image).resizable().interpolation(.high)
        Group {
            if #available(macOS 15.0, iOS 18.0, *) {
                i.widgetAccentedRenderingMode(.desaturated)
            } else {
                i
            }
        }
        .aspectRatio(contentMode: .fit)
    }
}

/// What to draw in a flight's logo slot.
enum FlightMarkKind: Equatable {
    /// A compact logo (roughly square).
    case logo(URL)
    /// The airline code in a tile, for airlines with no logo or only a wide wordmark that
    /// would be illegible at icon size.
    case monogram(String)
    /// The aircraft-class symbol, for flights with no airline.
    case aircraft(String)

    /// Logos wider than this (width / height) are wordmarks.
    static let wordmarkAspect: CGFloat = 1.9
    /// Logos darker than this vanish on a dark board (navy roundels); lighter than
    /// `maxBrightness` vanish on a light one.
    static let minBrightness = 0.12
    static let maxBrightness = 0.9

    /// - Parameters:
    ///   - brightness: alpha-weighted brightness of the logo (0…1), see `LogoTone`.
    ///   - darkBackground: the board behind the logo is dark (LED, or Standard in Dark Mode).
    static func resolve(_ f: Flight, logo: URL?, logoSize: CGSize?, brightness: Double? = nil,
                        darkBackground: Bool = true) -> FlightMarkKind {
        if let logo, let s = logoSize, s.height > 0, s.width / s.height < wordmarkAspect {
            let b = brightness ?? 0.5
            if darkBackground ? b >= minBrightness : b <= maxBrightness { return .logo(logo) }
        }
        if let code = monogram(for: f) { return .monogram(code) }
        return .aircraft(AircraftClass(typeCode: f.typeCode).symbol)
    }

    /// The airline's IATA code (2 characters) if known, else its ICAO code.
    static func monogram(for f: Flight) -> String? {
        if let iata = f.airlineCode?.uppercased(), (2...3).contains(iata.count) { return iata }
        return f.airlineICAO
    }
}

/// Measures how light a logo is, so logos that would disappear against the board are swapped out.
/// `LogoStore` computes it once per decoded logo.
enum LogoTone {
    /// Alpha-weighted perceived brightness (0…1) of an image's visible pixels.
    static func brightness(_ cg: CGImage) -> Double {
        let n = 24
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return 0.5 }
        var sum = 0.0, weight = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Double(px[i + 3]) / 255
            guard a > 0.05 else { continue }
            // Premultiplied: divide the alpha back out.
            let l = (0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])) / 255 / a
            sum += min(1, l) * a
            weight += a
        }
        return weight > 0 ? sum / weight : 0.5
    }
}

/// A flight's logo slot: the airline logo when there's a legible one, otherwise a monogram
/// tile or aircraft-class glyph, so rows never have a blank gap.
struct FlightMark: View {
    let flight: Flight
    let size: CGFloat
    @Environment(\.displayOptions) private var o
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if o.showLogos {
            let logo = LogoStore.logo(for: flight.logoKey?.id)
            content(FlightMarkKind.resolve(flight, logo: logo?.url, logoSize: logo?.size, brightness: logo?.brightness,
                                           darkBackground: !o.isStandard || scheme == .dark), logo?.image)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func content(_ kind: FlightMarkKind, _ img: PlatformImage?) -> some View {
        switch kind {
        case .logo:
            if let img { LogoImage(image: img) }
        case .monogram(let code):
            let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            Text(code)
                .font(.system(size: size * (code.count > 2 ? 0.4 : 0.48), weight: .heavy,
                              design: o.isStandard ? .rounded : .monospaced))
                .fontWidth(code.count > 2 ? .condensed : .standard)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, 1)
                .foregroundStyle(o.isStandard ? Color.primary.opacity(0.75) : o.theme.color.opacity(0.85))
                .frame(width: size, height: size)
                .background(shape.fill(o.isStandard ? Color.primary.opacity(0.09) : o.theme.color.opacity(0.1)))
                .overlay(shape.strokeBorder(o.isStandard ? Color.primary.opacity(0.12) : o.theme.color.opacity(0.4),
                                            lineWidth: 0.75))
        case .aircraft(let symbol):
            Image(systemName: symbol)
                .font(.system(size: size * 0.62, weight: .semibold))
                .foregroundStyle(o.dimColor)
        }
    }
}

/// The ↻ glyph in the header (the widget wraps it in a refresh button).
struct RefreshGlyph: View {
    @Environment(\.displayOptions) private var o
    var body: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(o.isStandard ? Color.secondary : o.theme.color.opacity(0.6))
            // A comfortable click target that doesn't push the header around.
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .padding(-6)
    }
}

// MARK: - Situation labels

extension FlightSituation {
    /// System colour: red for emergencies and hijack, orange for everything else.
    var tint: Color { severity == .critical ? .red : .orange }

    /// The colour on a board: LED red or orange segments, or the system colour in the Standard style.
    func color(_ o: DisplayOptions) -> Color {
        guard !o.isStandard else { return tint }
        return severity == .critical ? LEDTheme.red.color : Color(red: 1.0, green: 0.47, blue: 0.1)
    }
}

/// A flight's unusual situation, never animated: a filled pill with symbol and tag ("DIVERT MKE")
/// for the featured flight, or a symbol tile in a list row's logo slot. On the LED board it's an
/// inverse block of lit segments; in the Standard style a coloured capsule with white text.
struct SituationBadge: View {
    enum Style {
        /// Symbol and tag at this font size.
        case pill(CGFloat)
        /// Symbol only, in a square of this side.
        case tile(CGFloat)
    }

    let situation: FlightSituation
    let style: Style
    @Environment(\.displayOptions) private var o

    /// Text on the lit block: the board's unlit background colour.
    private static let ink = Color(red: 0.04, green: 0.035, blue: 0.03)

    var body: some View {
        let fill = situation.color(o)
        let ink = o.isStandard ? Color.white : Self.ink
        Group {
            switch style {
            case .pill(let size):
                HStack(spacing: size * 0.3) {
                    Image(systemName: situation.symbol).font(.system(size: size * 0.85, weight: .bold))
                    Text(situation.tag)
                        .font(.system(size: size, weight: .heavy, design: o.isStandard ? .default : .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(ink)
                .padding(.horizontal, size * 0.45)
                .padding(.vertical, size * 0.18)
                .background(shape(radius: size * 0.3).fill(fill).widgetAccentable())
            case .tile(let side):
                Image(systemName: situation.symbol)
                    .font(.system(size: side * 0.58, weight: .bold))
                    .foregroundStyle(ink)
                    .frame(width: side, height: side)
                    .background(shape(radius: side * 0.24).fill(fill).widgetAccentable())
            }
        }
        .shadow(color: o.glowEnabled ? fill.opacity(0.55) : .clear, radius: 3)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(situation.spoken)
    }

    /// A capsule in the Standard style; a squarer block, like a lit LED module, on the board.
    private func shape(radius: CGFloat) -> AnyShape {
        o.isStandard ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: radius * 0.5, style: .continuous))
    }
}

/// A featured flight's runway phase ("FINAL 28C · 6NM" / "Final 28C · 6 nm"): an outlined block of
/// lit segments on the LED board, a tinted capsule in the Standard style, orange for a go-around.
/// Quieter than `SituationBadge`, which takes its place when both apply.
struct ApproachTag: View {
    let phase: RunwayPhase
    let size: CGFloat
    /// Include the distance to the threshold on final (left out where space is tight).
    var distance = true
    @Environment(\.displayOptions) private var o

    private var tint: Color {
        if phase.isCaution { return FlightSituation.holding.color(o) }     // the board's caution orange
        return o.isStandard ? .blue : o.theme.color
    }

    var body: some View {
        if let text = phase.tag(o, distance: distance) {
            let c = tint
            Text(o.isStandard ? text : text.uppercased())
                .font(.system(size: size, weight: o.isStandard ? .semibold : .heavy, design: o.isStandard ? .default : .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(c)
                .padding(.horizontal, size * 0.45)
                .padding(.vertical, size * 0.18)
                .background {
                    if o.isStandard {
                        Capsule().fill(c.opacity(0.15))
                    } else {
                        RoundedRectangle(cornerRadius: size * 0.15, style: .continuous).strokeBorder(c, lineWidth: 1)
                    }
                }
                .shadow(color: o.glowEnabled ? c.opacity(0.5) : .clear, radius: 2.5)
                .widgetAccentable()
                .fixedSize()
                .accessibilityLabel(text)
        }
    }
}

// MARK: - Featured flight

struct FeaturedView: View {
    let f: Flight
    let layout: PanelLayout
    /// What the flight is doing at a runway, shown when it has no situation label.
    var phase: RunwayPhase? = nil
    /// The flight has the whole widget (list hidden): bigger codes, full stats.
    var hero = false
    @Environment(\.displayOptions) private var o

    private var m: PanelMetrics { PanelMetrics(layout: layout) }
    private var codeSize: CGFloat { hero ? m.heroCodeSize : m.codeSize }
    private var model: String { f.aircraft?.model ?? (f.typeCode.isEmpty ? "Unknown type" : f.typeCode) }

    var body: some View {
        Group { if layout == .small { small } else { regular } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([BoardFormat.spoken(f, o), phase?.tag(o.withStandardStyle)].compactMap { $0 }.joined(separator: ", "))
    }

    /// Shown under a route-less flight's callsign.
    private var subtitle: String {
        if f.looksLikeAirline { return "Route not verified" }
        let headline = f.callsign.isEmpty ? f.reg : f.callsign
        return f.reg != headline ? "Reg. \(f.reg)" : "General aviation"
    }

    // Small: identity, route, and the two numbers a spotter wants (how high, where to look).
    private var small: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                FlightMark(flight: f, size: 13)
                // No room for both: the situation (else the runway phase) replaces the operator.
                if let s = f.situation {
                    SituationBadge(situation: s, style: .pill(8.5))
                } else if let phase, phase.tag(o) != nil {
                    ApproachTag(phase: phase, size: 8.5, distance: false)
                } else {
                    LEDText(BoardFormat.operatorName(f), m.identitySize, dim: true)
                }
                Spacer(minLength: 2)
                LEDText(f.displayNumber, 10.5).fixedSize()
            }
            if let r = f.route {
                let to = f.destination ?? r.to
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        LEDText(r.from.code, codeSize, accent: true).fixedSize()
                        RouteLine(iconSize: 11, progress: f.progress)
                        LEDText(to.code, codeSize, accent: true, tint: changedTint).fixedSize()
                    }
                    if o.showCities {
                        HStack(spacing: 4) {
                            LEDText(r.from.city, m.citySize, dim: true, weight: .semibold)
                            Spacer(minLength: 4)
                            LEDText(to.city, m.citySize, dim: true, weight: .semibold)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    LEDText(f.callsign.isEmpty ? f.reg : f.callsign, codeSize, accent: true)
                    LEDText(subtitle, m.citySize, dim: true, weight: .semibold)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 3) {
                LEDText(model, 9.5, dim: true, weight: .semibold)
                HStack {
                    LEDText(f.climbSymbol + o.altitude(f.altitude), 11)
                    Spacer(minLength: 4)
                    LEDText(o.distance(f.distance) + " " + f.direction, 11).fixedSize()
                }
            }
        }
    }

    private var regular: some View {
        VStack(alignment: .leading, spacing: 6) {
            identity
            route
            if layout == .extraLarge && !hero { Spacer(minLength: 6) }
            stats.padding(.top, 2)
        }
    }

    private var identity: some View {
        HStack(spacing: 7) {
            FlightMark(flight: f, size: m.identitySize + 4)
            LEDText(BoardFormat.operatorName(f), m.identitySize, dim: true)
            Spacer(minLength: 6)
            if let s = f.situation {
                SituationBadge(situation: s, style: .pill(m.identitySize - 2))
            } else if let phase {
                ApproachTag(phase: phase, size: m.identitySize - 2)
            }
            LEDText(f.displayNumber, m.identitySize).fixedSize()
        }
    }

    /// The new destination's colour while diverting or returning.
    private var changedTint: Color? {
        f.pathSituation.flatMap { $0.newDestination == nil ? nil : $0.color(o) }
    }

    @ViewBuilder private var route: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let r = f.route {
                let to = f.destination ?? r.to
                HStack(spacing: 10) {
                    LEDText(r.from.code, codeSize, accent: true).fixedSize()
                    RouteLine(iconSize: min(20, codeSize * 0.42), progress: f.progress)
                    // "~~DEN~~ MKE": the scheduled destination struck through beside the new one.
                    HStack(alignment: .firstTextBaseline, spacing: codeSize * 0.15) {
                        if changedTint != nil { LEDText(r.to.code, codeSize * 0.4, dim: true, struck: true).fixedSize() }
                        LEDText(to.code, codeSize, accent: true, tint: changedTint).fixedSize()
                    }
                }
                if o.showCities {
                    HStack {
                        LEDText(r.from.city, m.citySize, dim: true, weight: .semibold)
                        Spacer(minLength: 8)
                        LEDText(to.city, m.citySize, dim: true, weight: .semibold)
                    }
                }
            } else {
                LEDText(f.callsign.isEmpty ? f.reg : f.callsign, codeSize, accent: true)
                if o.showCities { LEDText(subtitle, m.citySize, dim: true, weight: .semibold) }
            }
        }
    }

    @ViewBuilder private var stats: some View {
        switch hero ? PanelMetrics.Stats.fullGrid : m.stats {
        case .compact, .inline:
            HStack(spacing: 12) {
                LEDText(model, 12)
                Spacer(minLength: 4)
                LEDText(f.climbSymbol + o.altitude(f.altitude), 12).fixedSize()
                LEDText(o.speed(f.speed), 12).fixedSize()
                LEDText(o.distance(f.distance) + " " + f.direction, 12).fixedSize()
            }
        case .grid:
            VStack(alignment: .leading, spacing: 8) {
                aircraftLine
                HStack(alignment: .top, spacing: 8) {
                    StatCell(label: "Altitude", value: f.climbSymbol + o.altitude(f.altitude), m: m, hero: hero)
                    StatCell(label: "Speed", value: o.speed(f.speed), m: m, hero: hero)
                    StatCell(label: "From you", value: o.distance(f.distance) + " " + f.direction, m: m, hero: hero)
                }
            }
        case .fullGrid:
            VStack(alignment: .leading, spacing: 8) {
                aircraftLine
                HStack(alignment: .top, spacing: 8) {
                    StatCell(label: "Altitude", value: f.climbSymbol + o.altitude(f.altitude), m: m, hero: hero)
                    StatCell(label: "Speed", value: o.speed(f.speed), m: m, hero: hero)
                    StatCell(label: "Vertical", value: BoardFormat.verticalSpeed(f.verticalRate, o), m: m, hero: hero)
                }
                HStack(alignment: .top, spacing: 8) {
                    StatCell(label: "From you", value: o.distance(f.distance) + " " + f.direction, m: m, hero: hero)
                    StatCell(label: "Track", value: BoardFormat.track(f.track), m: m, hero: hero)
                    if let left = BoardFormat.toGo(f) {
                        StatCell(label: "To go", value: BoardFormat.longDistance(left, o), m: m, hero: hero)
                    } else {
                        StatCell(label: "Type", value: f.typeCode.isEmpty ? "—" : f.typeCode, m: m, hero: hero)
                    }
                }
            }
        }
    }

    private var aircraftLine: some View {
        HStack(spacing: 8) {
            LEDText(model, layout == .extraLarge ? 13 : 12)
            Spacer(minLength: 6)
            if !f.reg.isEmpty { LEDText(f.reg, layout == .extraLarge ? 12 : 11, dim: true).fixedSize() }
        }
    }
}

// MARK: - List rows

/// Column widths for list rows, shared by `RowView` and `RowHeader` so they line up.
struct RowColumns {
    let size: CGFloat
    let showLogos: Bool

    /// Width of `chars` characters at the row size (sized for the wider of the two styles).
    private func w(_ chars: Double) -> CGFloat { (CGFloat(chars) * size * 0.63).rounded(.up) }
    var spacing: CGFloat { 8 }
    var mark: CGFloat { size + 4 }
    var number: CGFloat { w(7.4) + (showLogos ? mark + 5 : 0) }
    var route: CGFloat { w(7.8) }
    var type: CGFloat { w(4.2) }
    var altitude: CGFloat { w(9.2) }
    var distance: CGFloat { w(6.6) }
    var direction: CGFloat { w(2.8) }
}

struct RowView: View {
    let f: Flight
    /// Show the full aircraft model instead of the ICAO type code.
    var wide = false
    var size: CGFloat = 11
    @Environment(\.displayOptions) private var o

    var body: some View {
        let c = RowColumns(size: size, showLogos: o.showLogos)
        HStack(spacing: c.spacing) {
            HStack(spacing: 5) {
                // The situation takes the logo's slot, so the columns don't move.
                if let s = f.situation {
                    SituationBadge(situation: s, style: .tile(c.mark))
                } else {
                    FlightMark(flight: f, size: c.mark)
                }
                LEDText(f.displayNumber, size)
            }
            .frame(width: c.number, alignment: .leading)
            LEDText(BoardFormat.route(f), size, dim: f.pathSituation == nil, tint: f.pathSituation?.color(o))
                .frame(width: c.route, alignment: .leading)
            LEDText(wide ? (f.aircraft?.model ?? f.typeCode) : f.typeCode, size, dim: true)
                .frame(minWidth: c.type, maxWidth: .infinity, alignment: .leading)
            LEDText(f.climbSymbol + o.altitude(f.altitude), size, dim: true)
                .frame(width: c.altitude, alignment: .trailing)
            LEDText(o.distance(f.distance), size)
                .frame(width: c.distance, alignment: .trailing)
            LEDText(f.direction, size, dim: true)
                .frame(width: c.direction, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BoardFormat.spoken(f, o))
    }
}

/// Column headings over the list, like a departures board.
struct RowHeader: View {
    var wide = false
    var size: CGFloat = 11
    @Environment(\.displayOptions) private var o

    var body: some View {
        let c = RowColumns(size: size, showLogos: o.showLogos)
        let label = { (t: String) in LEDText(t, 8.5, dim: true, weight: .semibold) }
        HStack(spacing: c.spacing) {
            label("FLIGHT").frame(width: c.number, alignment: .leading)
            label("ROUTE").frame(width: c.route, alignment: .leading)
            label(wide ? "AIRCRAFT" : "TYPE").frame(minWidth: c.type, maxWidth: .infinity, alignment: .leading)
            label("ALTITUDE").frame(width: c.altitude, alignment: .trailing)
            label("DIST").frame(width: c.distance, alignment: .trailing)
            Color.clear.frame(width: c.direction, height: 1)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Empty, loading and error states

/// A designed state for when there's no flight to feature, parsed from `PanelModel.status`.
/// Status strings read "Title — Detail"; the symbol is chosen from the wording.
struct PanelNotice: Equatable {
    var symbol: String
    var title: String
    var detail: String

    init(status: String) {
        let s = status.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else {
            self.init(symbol: "dot.radiowaves.left.and.right", title: "Scanning the skies", detail: "")
            return
        }
        let parts = s.components(separatedBy: " — ")
        let title = parts[0]
        var detail = parts.dropFirst().joined(separator: " — ")
        if let first = detail.first { detail = first.uppercased() + detail.dropFirst() }
        let l = s.lowercased()
        let symbol: String
        if l.contains("can't find") || l.contains("can’t find") { symbol = "mappin.slash" }
        else if l.contains("location") { symbol = "location.slash" }
        else if l.contains("quiet") || l.contains("nothing within") { symbol = "cloud.sun" }
        else if l.contains("connection") || l.contains("reach") || l.contains("offline") { symbol = "wifi.exclamationmark" }
        else { symbol = "exclamationmark.triangle" }
        self.init(symbol: symbol, title: title, detail: detail)
    }

    init(symbol: String, title: String, detail: String) {
        self.symbol = symbol; self.title = title; self.detail = detail
    }
}

struct NoticeView: View {
    let notice: PanelNotice
    let layout: PanelLayout
    @Environment(\.displayOptions) private var o

    var body: some View {
        let small = layout == .small
        VStack(spacing: small ? 5 : 7) {
            Image(systemName: notice.symbol)
                .font(.system(size: small ? 20 : 26, weight: .semibold))
                .foregroundStyle(o.isStandard ? Color.secondary : o.theme.color)
                .shadow(color: o.glowEnabled ? o.theme.color.opacity(0.55) : .clear, radius: 4)
                .widgetAccentable()
                .padding(.bottom, 2)
            LEDText(notice.title, small ? 11 : 13, lines: 2)
            if !notice.detail.isEmpty {
                LEDText(notice.detail, small ? 9 : 10.5, dim: true, weight: .semibold, lines: small ? 4 : 3)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: layout == .small ? .infinity : 300)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Whole panel

struct PanelContent: View {
    let model: PanelModel
    let layout: PanelLayout
    var accessory: AnyView? = nil
    @Environment(\.displayOptions) private var o

    private var m: PanelMetrics { PanelMetrics(layout: layout) }
    private var showsList: Bool { o.showList && m.supportsList }

    var body: some View {
        VStack(alignment: .leading, spacing: m.sectionSpacing) {
            if o.showHeader || accessory != nil { header }
            content
        }
        .padding(m.padding)
        .frame(maxWidth: .infinity, maxHeight: layout == .panel ? nil : .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            if o.showHeader {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.system(size: m.headerSize - 2, weight: .bold))
                        .foregroundStyle(o.dimColor)
                        .shadow(color: o.glowEnabled ? o.theme.color.opacity(0.3) : .clear, radius: 2)
                    LEDText(model.placeName.isEmpty ? "Nearby" : model.placeName, m.headerSize, dim: true)
                        .privacySensitive()
                }
                Spacer(minLength: 6)
                LEDText(headerStatus, m.headerSize, dim: true)
                    .fixedSize()
                    .invalidatableContent()
            } else {
                Spacer()
            }
            if let accessory { accessory }
        }
        .frame(height: m.headerHeight)
        .accessibilityElement(children: .contain)
    }

    /// Right side of the header: what's useful at a glance for each size.
    private var headerStatus: String {
        let time = model.updated?.formatted(date: .omitted, time: .shortened)
        let count = model.flights.isEmpty ? nil : "\(model.flights.count) in \(o.radius(model.radiusNM))"
        switch layout {
        case .small: return time ?? ""
        case .medium: return [count, time].compactMap { $0 }.joined(separator: " · ")
        case .large, .extraLarge: return time ?? ""          // the count lives in the footer
        case .panel: return count ?? ""                       // the panel is live; no clock
        }
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        if let f = model.featured {
            switch layout {
            case .small, .medium:
                featured(f).frame(maxHeight: .infinity, alignment: .top)
            case .panel:
                featured(f)
                if showsList {
                    rule
                    rows(Array(model.others.prefix(m.fixedRowCount ?? 4)))
                        .frame(height: m.rowsHeight(m.fixedRowCount ?? 4), alignment: .top)
                }
            case .large:
                if showsList {
                    featured(f)
                    rule
                    list
                } else {
                    hero(f)
                }
            case .extraLarge:
                if showsList {
                    HStack(alignment: .top, spacing: 18) {
                        featured(f).frame(width: 340).frame(maxHeight: .infinity, alignment: .top)
                        Rectangle().fill(o.ruleColor).frame(width: 1)
                        list
                    }
                } else {
                    hero(f)
                }
            }
        } else {
            NoticeView(notice: PanelNotice(status: model.status), layout: layout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: layout == .panel ? 228 : nil)
        }
    }

    private var rule: some View { Rectangle().fill(o.ruleColor).frame(height: 1) }

    private func featured(_ f: Flight) -> some View {
        FeaturedView(f: f, layout: layout, phase: model.runwayPhases[f.id])
            .modifier(FlightTarget(flight: f))
            .id(f.id)
            .transition(.opacity)
    }

    /// The featured flight on its own, centered in the widget.
    private func hero(_ f: Flight) -> some View {
        VStack {
            Spacer(minLength: 0)
            FeaturedView(f: f, layout: layout, phase: model.runwayPhases[f.id], hero: true)
                .frame(maxWidth: layout == .extraLarge ? 560 : .infinity)
                .modifier(FlightTarget(flight: f))
                .id(f.id)
                .transition(.opacity)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    /// The list fills whatever height is left, with a footer pinned to the bottom.
    private var list: some View {
        GeometryReader { geo in
            let footer = o.showHeader ? m.footerHeight + m.rowSpacing : 0
            let heading = m.showsColumnHeader ? m.columnHeaderHeight + m.rowSpacing : 0
            let shown = Array(model.others.prefix(m.rowsThatFit(geo.size.height - footer - heading)))
            VStack(alignment: .leading, spacing: m.rowSpacing) {
                if m.showsColumnHeader && !shown.isEmpty {
                    RowHeader(size: m.rowFont).frame(height: m.columnHeaderHeight)
                }
                if shown.isEmpty {
                    LEDText("No other aircraft in range", m.rowFont, dim: true, weight: .semibold)
                        .frame(height: m.rowHeight)
                } else {
                    rows(shown)
                }
                Spacer(minLength: 0)
                if o.showHeader { footerView(more: model.others.count - shown.count) }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rows(_ flights: [Flight]) -> some View {
        VStack(alignment: .leading, spacing: m.rowSpacing) {
            ForEach(flights) { f in
                RowView(f: f, wide: layout == .panel, size: m.rowFont)
                    .frame(height: m.rowHeight)
                    .modifier(FlightTarget(flight: f))
            }
        }
    }

    private func footerView(more: Int) -> some View {
        HStack {
            let n = model.flights.count
            LEDText("\(n) aircraft within \(o.radius(model.radiusNM))", 9, dim: true, weight: .semibold)
            Spacer(minLength: 6)
            if more > 0 { LEDText("+\(more) more", 9, dim: true, weight: .semibold).fixedSize() }
        }
        .frame(height: m.footerHeight)
    }
}

// MARK: - Gallery sample

extension PanelModel {
    /// A busy, believable sky for the widget gallery, placeholders and snapshots.
    static let gallery: PanelModel = {
        func ap(_ c: String, _ city: String, _ la: Double, _ lo: Double) -> Airport { Airport(code: c, city: city, lat: la, lon: lo) }
        let sea = ap("SEA", "Seattle", 47.45, -122.31), jfk = ap("JFK", "New York", 40.64, -73.78)
        let ord = ap("ORD", "Chicago", 41.98, -87.90), lhr = ap("LHR", "London", 51.47, -0.45)
        let den = ap("DEN", "Denver", 39.86, -104.67), bos = ap("BOS", "Boston", 42.36, -71.01)
        let dfw = ap("DFW", "Dallas", 32.90, -97.04), mem = ap("MEM", "Memphis", 35.04, -89.98)
        let slc = ap("SLC", "Salt Lake City", 40.79, -111.98), fra = ap("FRA", "Frankfurt", 50.03, 8.56)
        let phx = ap("PHX", "Phoenix", 33.43, -112.01), lax = ap("LAX", "Los Angeles", 33.94, -118.41)
        let flights = [
            sampleFlight("a1b2c3", "DAL1342", "N391DN", "A321", 34_000, 0, 468, 92, 4.2, 95, 39.75, -104.80,
                         ("Delta Air Lines", "DL1342", "DL", sea, jfk), "Airbus A321-211"),
            sampleFlight("a2b3c4", "UAL960", "N27965", "B789", 36_000, 0, 488, 61, 11.8, 40, 39.85, -104.70,
                         ("United Airlines", "UA960", "UA", ord, lhr), "Boeing 787-9"),
            sampleFlight("a3b4c5", "SWA2210", "N8703Q", "B38M", 7_200, -1400, 260, 172, 14.5, 160, 39.55, -104.80,
                         ("Southwest Airlines", "WN2210", "WN", ord, den), "Boeing 737 MAX 8"),
            sampleFlight("a4b5c6", "N172SP", "N172SP", "C172", 6_500, 0, 105, 220, 16.0, 220, 39.50, -105.10,
                         nil, "Cessna 172S Skyhawk"),
            sampleFlight("a5b6c7", "JBU488", "N3008J", "BCS3", 24_100, 900, 401, 284, 19.3, 300, 39.90, -105.20,
                         ("JetBlue", "B6488", "B6", bos, den), "Airbus A220-300"),
            sampleFlight("a6b7c8", "AAL2417", "N421UW", "A21N", 11_800, -1900, 290, 190, 21.6, 20, 40.05, -104.70,
                         ("American Airlines", "AA2417", "AA", dfw, den), "Airbus A321neo"),
            sampleFlight("a7b8c9", "FDX1207", "N116FE", "B763", 38_000, 0, 502, 275, 24.9, 110, 39.65, -104.40,
                         ("FedEx", "FX1207", "FX", mem, slc), "Boeing 767-300F"),
            sampleFlight("a8b9ca", "SKW5741", "N187SY", "E75L", 16_400, 2100, 330, 300, 27.0, 290, 39.80, -105.40,
                         ("SkyWest", "OO5741", "OO", den, slc), "Embraer E175"),
            sampleFlight("a9bacb", "DLH481", "D-AIXP", "A359", 39_000, 0, 512, 52, 31.4, 60, 40.10, -104.40,
                         ("Lufthansa", "LH481", "LH", den, fra), "Airbus A350-900"),
            sampleFlight("aabbcc", "N911FL", "N911FL", "EC35", 2_200, 0, 120, 340, 33.8, 330, 40.20, -105.10,
                         nil, "Airbus H135"),
            sampleFlight("abbccd", "FFT1311", "N365FR", "A20N", 28_700, 1200, 420, 225, 36.2, 210, 39.30, -105.00,
                         ("Frontier Airlines", "F91311", "F9", den, phx), "Airbus A320neo"),
            sampleFlight("acbdce", "UAL2033", "N37522", "B39M", 33_000, 0, 455, 245, 41.7, 235, 39.40, -105.30,
                         ("United Airlines", "UA2033", "UA", den, lax), "Boeing 737 MAX 9"),
        ]
        return PanelModel(flights: flights, placeName: "Denver", radiusNM: 50, updated: Date())
    }()

    /// A sample flight built from a feed record, as the live data would be.
    private static func sampleFlight(_ hex: String, _ cs: String, _ reg: String, _ t: String, _ alt: Int, _ vr: Double,
                                     _ gs: Double, _ trk: Double, _ d: Double, _ b: Double, _ lat: Double, _ lon: Double,
                                     _ route: (String, String, String, Airport, Airport)?, _ model: String,
                                     squawk: String? = nil) -> Flight {
        let code = squawk.map { ",\"squawk\":\"\($0)\"" } ?? ""
        let json = """
        {"hex":"\(hex)","flight":"\(cs)","r":"\(reg)","t":"\(t)","alt_baro":\(alt),"gs":\(gs),"track":\(trk),
         "lat":\(lat),"lon":\(lon),"dst":\(d),"dir":\(b),"baro_rate":\(vr)\(code)}
        """
        var fl = Flight(adsb: try! JSONDecoder().decode(ADSBAircraft.self, from: Data(json.utf8)))!
        if let r = route {
            fl.route = RouteInfo(airline: r.0, flightNo: r.1, airlineCode: r.2, from: r.3, to: r.4)
        }
        fl.aircraft = AircraftInfo(model: model, owner: route?.0)
        return fl
    }

    #if DEBUG
    /// The gallery sky with a diversion (featured) and an emergency (second), for snapshot renders
    /// of the situation labels. The diversion is detected by the real rules, not hard-coded.
    static let situations: PanelModel = {
        let ord = Airport(code: "ORD", city: "Chicago", lat: 41.98, lon: -87.90)
        let sfo = Airport(code: "SFO", city: "San Francisco", lat: 37.62, lon: -122.38)
        let las = Airport(code: "LAS", city: "Las Vegas", lat: 36.08, lon: -115.15)
        let bwi = Airport(code: "BWI", city: "Baltimore", lat: 39.18, lon: -76.67)
        // North of Denver, scheduled for San Francisco, turned south and descending toward DEN.
        var diverting = sampleFlight("adbecf", "UAL1189", "N37281", "B39M", 11_000, -1_500, 300, 185, 9.6, 5, 40.25, -104.70,
                                     ("United Airlines", "UA1189", "UA", ord, sfo), "Boeing 737 MAX 9")
        diverting.pathSituation = diverting.route.flatMap { FlightSituation.path(for: diverting, route: $0) }
        let mayday = sampleFlight("aecfd0", "SWA1984", "N8710M", "B38M", 14_200, -2_200, 340, 250, 12.4, 70, 39.85, -104.45,
                                  ("Southwest Airlines", "WN1984", "WN", bwi, las), "Boeing 737 MAX 8", squawk: "7700")
        var m = gallery
        m.flights = [diverting, mayday] + gallery.flights.prefix(10)
        return m
    }()

    /// The gallery sky with a flight 6 nm out on final for Denver's runway 16R (featured), for
    /// snapshot renders of the runway tag. The phase comes from the real analysis and runway table.
    static let approach: PanelModel = {
        let ord = Airport(code: "ORD", city: "Chicago", lat: 41.98, lon: -87.90)
        let den = Airport(code: "DEN", city: "Denver", lat: 39.86, lon: -104.67)
        let onFinal = sampleFlight("af0d1e", "UAL1543", "N76508", "B738", 7_300, -800, 145, 181, 10.6, 352, 39.9958, -104.6937,
                                   ("United Airlines", "UA1543", "UA", ord, den), "Boeing 737-800")
        var m = gallery
        m.flights = [onFinal] + gallery.flights.prefix(10)
        m.runwayPhases = RunwayPhase.listPhases(for: m.flights, previous: [:], phase: ApproachAnalyzer.listPhase)
        return m
    }()
    #endif
}
