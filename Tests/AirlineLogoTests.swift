import XCTest
import CoreGraphics
import ImageIO

final class AirlineLogoTests: XCTestCase {

    private func flight(callsign: String, route: RouteInfo? = nil) -> Flight {
        let json = """
        {"hex":"abc123","flight":"\(callsign)","t":"B738","alt_baro":30000,"gs":450,"track":90,
         "lat":40,"lon":-100,"dst":10,"dir":90,"baro_rate":0}
        """
        var f = Flight(adsb: try! JSONDecoder().decode(ADSBAircraft.self, from: Data(json.utf8)))!
        f.route = route
        return f
    }

    /// A 64×64 PNG; `draw` paints into a transparent canvas.
    private func png(_ draw: (CGContext) -> Void) -> Data {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    // MARK: Keys

    func testKeyFromCallsignWithoutRoute() {
        let k = flight(callsign: "SWA2210").logoKey
        XCTAssertEqual(k?.icao, "SWA")
        XCTAssertNil(k?.iata)
        XCTAssertEqual(k?.id, "SWA")
    }

    func testKeyCombinesCallsignAndRouteIATA() {
        let a = Airport(code: "DEN", city: "Denver", lat: 39.8, lon: -104.7)
        let k = flight(callsign: "JBU488", route: RouteInfo(airline: "JetBlue", flightNo: "B6488", airlineCode: "b6", from: a, to: a)).logoKey
        XCTAssertEqual(k?.icao, "JBU")
        XCTAssertEqual(k?.iata, "B6")
        XCTAssertEqual(k?.id, "JBU")
    }

    func testNoKeyForPrivateAircraft() {
        XCTAssertNil(flight(callsign: "N172SP").logoKey)
        XCTAssertNil(flight(callsign: "").logoKey)
    }

    func testKeyValidation() {
        XCTAssertNil(AirlineLogos.Key(icao: nil, iata: nil))
        XCTAssertNil(AirlineLogos.Key(icao: "S1A", iata: "W"))
        XCTAssertEqual(AirlineLogos.Key(icao: nil, iata: "9e")?.id, "9E")
        XCTAssertEqual(AirlineLogos.Key(icao: "edv", iata: "TOOLONG")?.iata, nil)
        XCTAssertNil(AirlineLogos.file(for: "../x"))
    }

    // MARK: Image checks

    func testTransparentLogoIsUsable() {
        let data = png { c in
            c.setFillColor(CGColor(srgbRed: 0.8, green: 0.1, blue: 0.2, alpha: 1))
            c.fillEllipse(in: CGRect(x: 8, y: 8, width: 48, height: 48))
        }
        XCTAssertTrue(AirlineLogos.isUsable(data))
    }

    func testSolidBackgroundIsRejected() {
        let data = png { c in
            c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0.6, alpha: 1))
            c.fillEllipse(in: CGRect(x: 16, y: 16, width: 32, height: 32))
        }
        XCTAssertFalse(AirlineLogos.isUsable(data))
    }

    func testRoundedTileIsRejected() {
        let data = png { c in
            c.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.8, alpha: 1))
            c.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 64, height: 64), cornerWidth: 10, cornerHeight: 10, transform: nil))
            c.fillPath()
        }
        XCTAssertFalse(AirlineLogos.isUsable(data))
    }

    func testBlankAndWhiteOnlyAreRejected() {
        XCTAssertFalse(AirlineLogos.isUsable(png { _ in }))
        let white = png { c in
            c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            c.fillEllipse(in: CGRect(x: 8, y: 8, width: 48, height: 48))
        }
        XCTAssertFalse(AirlineLogos.isUsable(white))
        XCTAssertFalse(AirlineLogos.isUsable(Data("<html>not found</html>".utf8)))
    }

    func testSVGIsRasterizedToTransparentPNG() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50" width="100" height="50">
        <rect x="10" y="5" width="80" height="40" fill="#c00"/></svg>
        """
        let data = try XCTUnwrap(AirlineLogos.rasterizedSVG(Data(svg.utf8)))
        XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let img = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        // Rendered at 128 px wide, then the transparent margin is trimmed (1 px kept).
        XCTAssertEqual(Double(img.width) / Double(img.height), 2, accuracy: 0.15)
        XCTAssertLessThanOrEqual(img.width, 128)
        XCTAssertNil(AirlineLogos.rasterizedSVG(Data("nope".utf8)))
    }

    // MARK: Catalog

    func testCatalogParsing() {
        let json = """
        [{"slug":"southwest-airlines","iata":"WN","icao":"SWA","assets":{"icon":{"color":true}}},
         {"slug":"old-air","iata":"WN","icao":"OLD","defunct":true,"assets":{"icon":{"color":true}}},
         {"slug":"logo-only","iata":"LO","icao":"LGO","assets":{"logo":{"color":true}}},
         {"slug":"dup-air","iata":"SL","icao":"DUP","iata_duplicate":true,"assets":{"icon":{"color":true}}},
         {"slug":"../evil","iata":"EV","icao":"EVL","assets":{"icon":{"color":true}}}]
        """
        let map = SoaringSymbols.parse(Data(json.utf8))
        XCTAssertEqual(map["ICAO:SWA"], "southwest-airlines")
        XCTAssertEqual(map["IATA:WN"], "southwest-airlines")
        XCTAssertNil(map["ICAO:OLD"])
        XCTAssertNil(map["ICAO:LGO"])
        XCTAssertEqual(map["ICAO:DUP"], "dup-air")
        XCTAssertNil(map["IATA:SL"])
        XCTAssertNil(map["ICAO:EVL"])
    }
}
