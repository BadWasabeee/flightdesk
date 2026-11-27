import XCTest

/// Layout rules for the desktop widget and floating panel (`Shared/FlightViews.swift`).
final class WidgetLayoutTests: XCTestCase {

    private func flight(callsign: String, type: String = "B738", route: RouteInfo? = nil) -> Flight {
        let json = """
        {"hex":"abc123","flight":"\(callsign)","t":"\(type)","alt_baro":30000,"gs":450,"track":90,
         "lat":40,"lon":-100,"dst":10,"dir":90,"baro_rate":0}
        """
        var f = Flight(adsb: try! JSONDecoder().decode(ADSBAircraft.self, from: Data(json.utf8)))!
        f.route = route
        return f
    }

    private let den = Airport(code: "DEN", city: "Denver", lat: 39.86, lon: -104.67)
    private let jfk = Airport(code: "JFK", city: "New York", lat: 40.64, lon: -73.78)

    // MARK: Metrics

    func testRowsThatFitMatchesRowsHeight() {
        for layout in [PanelLayout.large, .extraLarge, .panel] {
            let m = PanelMetrics(layout: layout)
            for n in 1...14 {
                XCTAssertEqual(m.rowsThatFit(m.rowsHeight(n)), n, "\(layout) \(n) rows")
                XCTAssertEqual(m.rowsThatFit(m.rowsHeight(n) - 1), n - 1, "\(layout) just short of \(n) rows")
            }
            XCTAssertEqual(m.rowsThatFit(0), 0)
            XCTAssertEqual(m.rowsThatFit(-20), 0)
        }
    }

    func testOnlyListFamiliesShowRows() {
        XCTAssertFalse(PanelMetrics(layout: .small).supportsList)
        XCTAssertFalse(PanelMetrics(layout: .medium).supportsList)
        XCTAssertTrue(PanelMetrics(layout: .large).supportsList)
        XCTAssertTrue(PanelMetrics(layout: .extraLarge).supportsList)
        XCTAssertEqual(PanelMetrics(layout: .panel).fixedRowCount, 4)
        XCTAssertNil(PanelMetrics(layout: .large).fixedRowCount)
    }

    func testTypeHierarchyGrowsWithFamily() {
        let sizes = [PanelLayout.small, .medium, .large, .extraLarge].map { PanelMetrics(layout: $0).codeSize }
        XCTAssertEqual(sizes, sizes.sorted(), "route codes should never shrink as the widget grows")
        for layout in [PanelLayout.small, .medium, .large, .extraLarge, .panel] {
            let m = PanelMetrics(layout: layout)
            XCTAssertGreaterThan(m.codeSize, m.identitySize * 2, "\(layout): codes must dominate")
            XCTAssertGreaterThan(m.identitySize, m.citySize - 0.01)
            XCTAssertGreaterThan(m.heroCodeSize, m.codeSize - 0.01)
        }
    }

    func testRowColumnsFitTheirFamilies() {
        // Fixed columns + spacing + the type column's minimum must fit the list width.
        func fits(_ size: CGFloat, _ width: CGFloat) -> Bool {
            let c = RowColumns(size: size, showLogos: true)
            let total = c.number + c.route + c.type + c.altitude + c.distance + c.direction + 5 * c.spacing
            return total <= width
        }
        XCTAssertTrue(fits(PanelMetrics(layout: .large).rowFont, 364 - 32), "large")
        XCTAssertTrue(fits(PanelMetrics(layout: .extraLarge).rowFont, 765 - 32 - 340 - 37), "XL list column")
        XCTAssertTrue(fits(PanelMetrics(layout: .panel).rowFont, 460 - 32), "panel")
    }

    // MARK: Logo slot

    func testWideWordmarkFallsBackToMonogram() {
        let f = flight(callsign: "JBU488", route: RouteInfo(airline: "JetBlue", flightNo: "B6488", airlineCode: "B6", from: den, to: jfk))
        let url = URL(fileURLWithPath: "/tmp/JBU.png")
        XCTAssertEqual(FlightMarkKind.resolve(f, logo: url, logoSize: CGSize(width: 90, height: 33)), .monogram("B6"))
        XCTAssertEqual(FlightMarkKind.resolve(f, logo: url, logoSize: CGSize(width: 128, height: 106)), .logo(url))
    }

    func testLogosThatVanishAgainstTheBoardFallBack() {
        let f = flight(callsign: "DLH481", route: RouteInfo(airline: "Lufthansa", flightNo: "LH481", airlineCode: "LH", from: den, to: jfk))
        let url = URL(fileURLWithPath: "/tmp/DLH.png"), square = CGSize(width: 128, height: 128)
        // A navy roundel disappears on the dark board but is fine on a light one.
        XCTAssertEqual(FlightMarkKind.resolve(f, logo: url, logoSize: square, brightness: 0.09, darkBackground: true), .monogram("LH"))
        XCTAssertEqual(FlightMarkKind.resolve(f, logo: url, logoSize: square, brightness: 0.09, darkBackground: false), .logo(url))
        // A white logo is the reverse.
        XCTAssertEqual(FlightMarkKind.resolve(f, logo: url, logoSize: square, brightness: 0.97, darkBackground: false), .monogram("LH"))
        XCTAssertEqual(FlightMarkKind.resolve(f, logo: url, logoSize: square, brightness: 0.97, darkBackground: true), .logo(url))
    }

    func testLogoBrightness() {
        func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat = 1) -> CGImage {
            let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: alpha))
            ctx.fill(CGRect(x: 8, y: 8, width: 16, height: 16))   // transparent border is ignored
            return ctx.makeImage()!
        }
        XCTAssertEqual(LogoTone.brightness(solid(1, 1, 1)), 1, accuracy: 0.02)
        XCTAssertEqual(LogoTone.brightness(solid(0, 0, 0)), 0, accuracy: 0.02)
        XCTAssertLessThan(LogoTone.brightness(solid(0.02, 0.09, 0.3)), FlightMarkKind.minBrightness, "navy")
        XCTAssertEqual(LogoTone.brightness(solid(1, 1, 1, alpha: 0.5)), 1, accuracy: 0.05, "translucent white is still white")
    }

    func testMissingLogoUsesICAOWhenNoIATA() {
        XCTAssertEqual(FlightMarkKind.resolve(flight(callsign: "SKW5741"), logo: nil, logoSize: nil), .monogram("SKW"))
    }

    func testGeneralAviationUsesAircraftGlyph() {
        XCTAssertEqual(FlightMarkKind.resolve(flight(callsign: "N172SP", type: "C172"), logo: nil, logoSize: nil), .aircraft("airplane"))
        XCTAssertEqual(FlightMarkKind.resolve(flight(callsign: "N911FL", type: "EC35"), logo: nil, logoSize: nil), .aircraft("fanblades.fill"))
    }

    // MARK: States

    func testNoticeSplitsTitleAndDetail() {
        let n = PanelNotice(status: "Quiet skies — nothing within 25 nm right now")
        XCTAssertEqual(n.title, "Quiet skies")
        XCTAssertEqual(n.detail, "Nothing within 25 nm right now")
        XCTAssertEqual(n.symbol, "cloud.sun")
    }

    func testNoticeSymbols() {
        XCTAssertEqual(PanelNotice(status: "No location — open Settings").symbol, "location.slash")
        XCTAssertEqual(PanelNotice(status: "Can't find “Atlantis” — Edit the widget").symbol, "mappin.slash")
        XCTAssertEqual(PanelNotice(status: "Can't reach flight data — retrying").symbol, "wifi.exclamationmark")
        XCTAssertEqual(PanelNotice(status: "No connection — retrying").symbol, "wifi.exclamationmark")
        XCTAssertEqual(PanelNotice(status: "Something odd").symbol, "exclamationmark.triangle")
        XCTAssertEqual(PanelNotice(status: "Something odd").detail, "")
    }

    func testEmptyStatusIsLoading() {
        let n = PanelNotice(status: "")
        XCTAssertEqual(n.title, "Scanning the skies")
        XCTAssertTrue(n.detail.isEmpty)
    }

    // MARK: Formatting

    func testVerticalSpeed() {
        var o = DisplayOptions()
        XCTAssertEqual(BoardFormat.verticalSpeed(1840, o), "+1,800FPM")
        XCTAssertEqual(BoardFormat.verticalSpeed(-120, o), "LEVEL")
        o.style = .standard
        XCTAssertEqual(BoardFormat.verticalSpeed(-1400, o), "−1,400 fpm")
        o.units = .metric
        XCTAssertEqual(BoardFormat.verticalSpeed(1000, o), "+5.1 m/s")
    }

    func testLongDistanceDropsDecimals() {
        var o = DisplayOptions()
        XCTAssertEqual(BoardFormat.longDistance(1104.4, o), "1,104NM")
        XCTAssertEqual(BoardFormat.longDistance(42.25, o), o.distance(42.25))
        o.style = .standard; o.units = .metric
        XCTAssertEqual(BoardFormat.longDistance(1000, o), "1,852 km")
    }

    func testTrackAndRoute() {
        XCTAssertEqual(BoardFormat.track(5), "005°")
        XCTAssertEqual(BoardFormat.track(359.7), "000°")
        XCTAssertEqual(BoardFormat.track(nil), "—")
        let f = flight(callsign: "DAL1", route: RouteInfo(airline: "Delta", flightNo: "DL1", from: den, to: jfk))
        XCTAssertEqual(BoardFormat.route(f), "DEN›JFK")
        XCTAssertEqual(BoardFormat.route(flight(callsign: "N1")), "—")
        XCTAssertNotNil(BoardFormat.toGo(f))
    }

    func testOperatorNameFallbacks() {
        XCTAssertEqual(BoardFormat.operatorName(flight(callsign: "N172SP")), "General aviation")
        XCTAssertEqual(BoardFormat.operatorName(flight(callsign: "SKW5741")), "SKW")
    }

    // MARK: Gallery

    func testGallerySkyFillsTheLargestWidget() {
        let g = PanelModel.gallery
        XCTAssertGreaterThanOrEqual(g.others.count, 10, "the XL gallery preview should have a full list")
        XCTAssertNotNil(g.featured?.route, "the gallery leads with a routed flight")
        XCTAssertEqual(Set(g.flights.map(\.id)).count, g.flights.count, "unique ids")
        XCTAssertTrue(g.flights.allSatisfy { FlightLink.hex(from: FlightLink.url(for: $0.id)) == $0.id }, "deep-linkable ids")
        XCTAssertEqual(g.flights.map(\.distance), g.flights.map(\.distance).sorted(), "nearest first, like live data")
    }
}
