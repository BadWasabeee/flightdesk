import XCTest

/// Readable decodes of ACARS message contents, from real messages in the Airframes.io feed
/// (November 2026): FMS position reports, wind requests and flight plans, OOOI, D-ATIS,
/// clearances, takeoff data, FANS-1/A (ARINC 622) and MIAM (ARINC 841).
final class AcarsDecoderTests: XCTestCase {

    private let userSample = #"T32!<</@/jq9W8Q\YP!'s.16q2MV<h]Qo|D,T,K'/9poQ$LEnfWgtTq_Zd).&'sGGhCUT<bNfC9%EpU3)15d;._*.3BhGCSLj&"baahmr*NOnhgDs2bR#^Af%XK?5:\MMYt%]cf@ueVh>Nq0R'79uP_kAZP;mQEH,kcuIl_DD]C#:oD>--H9G;h_XU^h/(KiX8&JP@Nl/U7gfCA%25G#SRSpj@O+-,OKnF1fhIX?Nk3mES%5JYAZ%[D;G?1\Jm)YA4a$pl+7.j2>1,RqZsi]sjq`Z6c<@Y%)8#TOBtL^tbSjX[-KACM41l1uJjqP$O#q5CE0Y_4Z3HH!1>440a9E8Z9-/'cM;r0L?;b-<J.e^b=N*Uu0D`g<5!a5iDIJb\Hq`F:E@KB_'no87E:],,K^WKDC-SiA[iKZkG-EbUoTZW($h^"A[mC-hkP):hu.3dC8M?_.sRfoi1fZUTo:[DkoWbr+',^!bmU>H3Y;i5.CoR$t8Q>kWHn?F.USUP9&G+u_lMCYVo];L2'1<FT"]Q]UMjh0R<]2+%rcom%d1.L?,.<4!i?0c)`99$e-#+XclNhZ*WV"#
    private let finnairGear = #"T32!<</(/l,"i9NP3,!'s.16q548I5Cp(|AWkeC)aOme?Y/[\?(^9/?=g0&WZj]&Ug-D>6:`q(Zkn.<Ia8W0Cc7aPI.hf6O(W$\M4%:^&q%<JqeuD?^1E!knc-%+TskbJpg]@GIC\%$?gW&J`2&)T82IMJ8n<Xcb.,9BrH>dneeagJFReBp9S\2-Cc,YF(jF4bmoW[(D05aKr9*Q/>TJj>+--*5jk\m@=TADFGPq@-F<"B!Y6Qc,,9Bq5KpdSf#t-hZeql6q>nH>?CF<FSiW`Mb#JgP+B$t9(]CLPq(!7s2VK$/T4nbmGk0ntH,/ugb#`-e6BAu3h4gS`,c'B/#?&tdV,XpkL8a^5"!bn3i\VbtgS3P'(I#==7eoULNaV^B*eK'&LF+[6o4iDU9ePbAL(-Xm`<Q-D\3nW5tN`3S>Oc"aZ7d2,\'Pp`(To5FF'[id#/fF(<i\Gm"YsGXLNGNikNCCn0HHmibhtrp`7]ncGS2`APgaRVSi6umR/96KVL8L!g;>W?p4:DN`?mqS^E*2=/naJQ0Tp8tlz"#
    private let truncated = #"T32!<</(/l,"i9NP3,!'s.16q548I5Cp(|AWkeC)aOme?Y/[\?(^9/?=g0&WZj]&Ug-D>6:`q(Zkn.<Ia8W0Cc7aPI.hf6O(W$\M4%:^&q%<JqeuD?^1E!knc-%+TskbJpg]@GIC\%$?gW&J`2&)T82IMJ8n<Xcb.,9BrH>dneeagJFReBp9S\2-Cc,YF(jF4bmoW[(D05aKr9*Q/>"#

    private func message(_ label: String, _ text: String, at iso: String = "2026-11-27T03:51:20.000Z") throws -> AcarsMessage {
        let json: [String: Any] = ["id": 1, "timestamp": iso, "label": label, "text": text, "sourceType": "vdl"]
        let data = try JSONSerialization.data(withJSONObject: json)
        return AcarsMessage(try AirframesAPI.decoder().decode(AirframesAPI.Message.self, from: data), aircraftHex: "abc123")
    }

    private func value(_ m: AcarsMessage, _ name: String) -> String? { m.fields.first { $0.name == name }?.value }

    // MARK: FMS messages

    func testPositionReport() throws {
        let m = try message("H1", "POSN42285W087484,BRTMN,035113,174,TAAYZ,035331,PETTY,M15,06645,130641CE")
        XCTAssertEqual(m.plainLabel, "Position report")
        XCTAssertTrue(try XCTUnwrap(value(m, "Position")).hasPrefix("42.475° N, 87.807° W"))
        XCTAssertEqual(value(m, "Reported"), "03:51:13Z")
        XCTAssertEqual(value(m, "Last waypoint"), "BRTMN")
        XCTAssertEqual(value(m, "Altitude"), "FL174")
        XCTAssertEqual(value(m, "Next"), "TAAYZ at 03:53Z")
        XCTAssertEqual(value(m, "Then"), "PETTY")
        XCTAssertEqual(value(m, "Outside air"), "−15 °C")
        XCTAssertEqual(value(m, "Wind"), "066° at 45 kt")
        // Cruise over the Pacific: a six-digit wind (over 100 kt is written with three digits).
        let p = try message("H1", "POSN32330W120209,FOOTS,035320,370,SXC,040713,SLAER,M53,324070,108,466,461K,258K,733AE4", at: "2026-11-27T03:53:30.000Z")
        XCTAssertEqual(value(p, "Next"), "SXC at 04:07Z")
        XCTAssertEqual(value(p, "Wind"), "324° at 70 kt")
        XCTAssertEqual(value(p, "Outside air"), "−53 °C")
        // An empty passed waypoint is left out; one given as a coordinate is shown as one.
        let q = try message("H1", "POSN41122W113440,,035444,270,RAP,045510,FAR,M33,29557,1637/TS035444,27112691A9", at: "2026-11-27T03:54:46.000Z")
        XCTAssertNil(value(q, "Last waypoint"))
        let c = try message("H1", "POSN37488W075362,N37079W076007,035747,370,N37497W075356,035758,N38034W075272,M49,20182,155/TS035747,2711267E3E", at: "2026-11-27T03:57:50.000Z")
        XCTAssertEqual(value(c, "Last waypoint"), "37.1N 76.0W")
        XCTAssertEqual(value(c, "Next"), "37.8N 75.6W at 03:57Z")
        XCTAssertEqual(value(q, "Next"), "RAP at 04:55Z")
    }

    func testTemperatureAndWindFields() {
        XCTAssertEqual(AcarsContentDecoder.temperature("P2"), "2 °C")
        XCTAssertEqual(AcarsContentDecoder.temperature("M0"), "0 °C")
        XCTAssertNil(AcarsContentDecoder.temperature("15"))
        XCTAssertNil(AcarsContentDecoder.temperature("M150"))
        XCTAssertEqual(AcarsContentDecoder.wind("252101"), "252° at 101 kt")
        XCTAssertNil(AcarsContentDecoder.wind("4"))
        XCTAssertNil(AcarsContentDecoder.wind("999999"))
        XCTAssertNil(AcarsContentDecoder.wind("06A45"))
    }

    func testWindRequest() throws {
        let m = try message("H1", "REQPWI/WQ370.380.390.400:N39539W071575.SLATN.SOORY.N40W050.N40W040.N42W030.N44W020.MUDOS.STG.DESAT.ZMR.PDT.AKOKI.NANDO.MINGU.ABOSI.MABUX.RETBA.MOPIR.LASPO.ORVUS.GODOX.EDULI.PTC.SOTAX.RISEP.ETOIL.XATOS.IBREP")
        XCTAssertEqual(m.summary, "Requested winds for FL370–FL400 along 28 waypoints: 39.9N 72.0W → … → XATOS")
        XCTAssertEqual(value(m, "Levels"), "FL370, FL380, FL390, FL400")
    }

    func testFlightPlan() throws {
        let m = try message("H1", "FPN/FNWZZ4ZH/RI:DA:LBSF:AA:EPWA:F:OGOTA.N133..LOMOS..NARKA..LENOV..ORTEB..KONZI..LOGDA853E")
        XCTAssertEqual(m.plainLabel, "Flight plan")
        XCTAssertEqual(m.summary, "Flight plan LBSF → EPWA via 6 waypoints")
        XCTAssertEqual(value(m, "Waypoints"), "OGOTA LOMOS NARKA LENOV ORTEB KONZI")
        let b = try message("H1", "FPN/FNVOZ1641/RP..SANEG,S27491E153026.H91.ADMAR.Q78.OLTIN.H201.TESAT.H65.WOL.H20.OTKED.J22.LT:DA:YBBN:AA:YMLT229C")
        XCTAssertEqual(value(b, "Route"), "YBBN → YMLT")
    }

    // MARK: OOOI

    func testOffReport() throws {
        let m = try message("QQ", "CYVRCYXE0402/FB  152", at: "2026-11-27T04:02:40.540Z")
        XCTAssertEqual(m.summary, "Took off from CYVR, 04:02Z")
        XCTAssertEqual(value(m, "Off"), "04:02Z")
        XCTAssertEqual(value(m, "Route"), "CYVR → CYXE")
        XCTAssertEqual(m.event?.kind, .off)
        // Without airports and a time, the message time stands in and there's no summary.
        let bare = try message("QA", "OUT")
        XCTAssertNil(bare.summary)
        XCTAssertEqual(value(bare, "Out"), "03:51Z")
    }

    // MARK: Weather

    func testATIS() throws {
        let lax = try message("A9", "/ATSF9XA.TI2/KLAX ARR ATIS M\r\n0353Z LAX ATIS INFO M 0353Z. 00000KT 10SM\r\nFEW250 19/16 A3008 (THREE ZERO ZERO\r\nEIGHT) RMK AO2 SLP184 T01890156. INST\r\nAPCHS AND RNAV RNP APCHS RY 24R AND 25L,\r\nOR VCTR FOR VISUAL APCH WILL ")
        XCTAssertEqual(lax.plainLabel, "ATIS")
        XCTAssertEqual(lax.summary, "KLAX arrival ATIS information M")
        XCTAssertEqual(value(lax, "Issued"), "0353Z")
        XCTAssertEqual(value(lax, "Wind"), "Calm")
        XCTAssertEqual(value(lax, "Visibility"), "10 statute miles")
        XCTAssertEqual(value(lax, "Cloud"), "Few at \(25_000.formatted()) ft")
        XCTAssertEqual(value(lax, "Temperature"), "19 °C, dew point 16 °C")
        XCTAssertEqual(value(lax, "Altimeter"), "30.08 inHg")
        let sea = try message("A9", "/ATSHAXA.TI2/KSEA ARR ATIS I\r\n\t0353Z SEA ATIS INFO I 0353Z. 17010KT 10SM BKN042 10/09 A3016 (THREE ZERO ONE SIX).")
        XCTAssertEqual(value(sea, "Wind"), "170° at 10 kt")
        XCTAssertEqual(value(sea, "Cloud"), "Broken at \(4_200.formatted()) ft")
        // Non-METAR wording (metres per second, "QNH 1020 HPA") is left as sent.
        let canton = try message("A9", "/BJSATYA.TI2/ZGGG ARR ATIS X\n\t0342Z EXP ILS Z/VIS APCH\n\tINDEPENDENT PARL INSTR APCH \n\tLDG RWY 01L & 02R & 03\n\tWIND VRB DEG 1 MPS\n\tCAVOK\n\tT 23 /DP 14\n\tQNH 1020 HPA\n\tADZ YOU HAVE INFO X.9709")
        XCTAssertEqual(canton.summary, "ZGGG arrival ATIS information X")
        XCTAssertEqual(canton.fields.map(\.name), ["Issued", "Visibility"])
        XCTAssertEqual(try message("B9", "/KJFK.TI2/024KJFKA6588").summary, "ATIS requested for KJFK")
        // A continuation block without the header isn't guessed at.
        XCTAssertNil(try message("A9", "OU HAVE INFO I.983B").summary)
    }

    // MARK: Clearances

    func testOceanicClearanceRequests() throws {
        let m = try message("B1", "/REKCLXS.OC1/RCL 024\r\nGTI6079-RATSU/0503 M082F300\r\n-RMK/MAX FL340\r\nTMI 331558E")
        XCTAssertEqual(m.plainLabel, "Oceanic clearance request")
        XCTAssertEqual(m.summary, "GTI6079 requests oceanic clearance")
        XCTAssertEqual(m.fields.map(\.value), ["RATSU at 05:03Z", "Mach 0.82", "FL300", "FL340"])
        let gander = try message("B1", "/CZQX.OC1/RCL 046\r\nACA842-JANJO/0526 M084F350\r\n-RMK/MAX F35026F3")
        XCTAssertEqual(gander.summary, "ACA842 requests oceanic clearance from CZQX")
        XCTAssertEqual(value(gander, "Highest acceptable"), "FL350")
    }

    func testDepartureClearances() throws {
        let request = try message("B3", "/LEVC.DC1/RCD 000\r\nPVG127P-LEVC-GATE 54-GCLP\r\nATIS E\r\n-TYP/A32123AC")
        XCTAssertEqual(request.summary, "PVG127P requests departure clearance at LEVC")
        XCTAssertEqual(request.fields.map(\.value), ["LEVC → GCLP", "54", "E"])
        let pdc = try message("A3", "/ANPOC5Y.DC1/CLD 0403 261127 PANC\n\tPDC 2\n\tGTI875 PANC-ZHEC\n\tSQUAWK: 7220\n\tEDT: 0420 EDCT: 0420\n\tFILED FL: 380\n\tEQUIP: H/B748/L\n\t********************\n\tREVIEW ATC INSTRUCTIONS\n\tEND OF CLEARANCEF6D8")
        XCTAssertEqual(pdc.summary, "Departure clearance for GTI875")
        XCTAssertEqual(pdc.fields.map(\.value), ["PANC → ZHEC", "7220", "FL380"])
        let status = try message("A4", "/BCNCDYA.FS1/FSM 0358 261127 LEVC\r\nPVG127P RCD RECEIVED\r\nREQUEST BEING PROCESSED\r\nSTANDBY9706")
        XCTAssertEqual(status.summary, "LEVC at 03:58Z: PVG127P RCD RECEIVED · REQUEST BEING PROCESSED")
        let confirmed = try message("A4", "/HELCLXA.FS1/FSM 0359 261127 EFHK\r\nFIN4AN CDA RECEIVED\r\nCLEARANCE CONFIRMEDD5E7")
        XCTAssertEqual(confirmed.summary, "EFHK at 03:59Z: FIN4AN CDA RECEIVED · CLEARANCE CONFIRMED")
    }

    func testTakeoffAndLandingData() throws {
        let to = try message("31", "KTPA T/O DATA\r\nFLT  1251  RLS  1  0401Z\r\nWX 286M09     18C A3005\r\nKTPA 01L         DT H008\r\nFLEX - PACKS ON\r\n \r\nV1 149  FL/THS   1/UP0.5\r\nVR 152          54C FLEX\r\nV2 153          EO  1027\r\n \r\nKTPA 01L           11002")
        XCTAssertEqual(to.plainLabel, "Takeoff data")
        XCTAssertEqual(value(to, "Runway"), "01L at KTPA")
        XCTAssertEqual(value(to, "Speeds"), "V1 149 kt, VR 152 kt, V2 153 kt")
        let ldg = try message("33", "KSMF LDG DATA\n\tFLT        LDW      TIME\n\t0820      340.4    0400Z")
        XCTAssertEqual(ldg.plainLabel, "Landing data")
        XCTAssertTrue(ldg.fields.isEmpty)
    }

    // MARK: FANS-1/A

    func testArinc622() throws {
        let adsc = try message("B6", "/MLOCAYA.ADS.F-OLRB07225E4816C485F236DA9F2145", at: "2026-11-27T03:58:32.375Z")
        XCTAssertEqual(adsc.plainLabel, "ADS-C periodic report")
        XCTAssertTrue(try XCTUnwrap(value(adsc, "Position")).hasPrefix("48.330° N, 4.002° E"))
        XCTAssertEqual(value(adsc, "Altitude"), "\(24_352.formatted()) ft")
        XCTAssertEqual(value(adsc, "Time"), "58:30.6 past the hour")
        // A corrupted body fails the CRC: named, not decoded.
        let bad = try message("B6", "/MLOCAYA.ADS.F-OLRB07225E4816C485F236DA9F2146")
        XCTAssertEqual(bad.plainLabel, "ADS-C report (encoded)")
        XCTAssertTrue(bad.fields.isEmpty)
        // Uplinks are contract requests, whose tags mean something else.
        XCTAssertEqual(try message("A6", "/BNECAYA.ADS.B-5966080713235A22F60A244C4F").plainLabel, "ADS-C contract request (encoded)")
        XCTAssertEqual(try message("BA", "/USADCXA.AT1.N614DN66983DAE0062AF").plainLabel, "CPDLC message (encoded)")
        XCTAssertEqual(try message("BA", "/YYZE2YA.DR1.C-FVLQ7CF8").plainLabel, "CPDLC disconnection")
        XCTAssertEqual(CRC.arinc16(Array("ADS.F-OLRB".utf8) + [0x07, 0x22, 0x5E, 0x48, 0x16, 0xC4, 0x85, 0xF2, 0x36, 0xDA, 0x9F, 0x21, 0x45]), 0x1D0F)
    }

    // MARK: MIAM

    func testBase85AndChecksums() {
        XCTAssertEqual(MIAM.base85(Array("9jqo^".utf8)), Array("Man ".utf8))
        XCTAssertEqual(MIAM.base85(Array("z".utf8)), [0, 0, 0, 0])
        XCTAssertNil(MIAM.base85(Array("9jqov".utf8)))      // "v" is outside the alphabet
        XCTAssertNil(MIAM.base85(Array("uuuuu".utf8)))      // more than 32 bits
        XCTAssertEqual(CRC.arinc16(Array("123456789".utf8)), 0x29B1)
        XCTAssertEqual(CRC.arinc665(Array("123456789".utf8)), 0xFC89_1918)
    }

    func testCompressedMIAMMessage() throws {
        // The sample a user asked about: a complete single transfer, deflate-compressed, CRC good.
        let m = try message("MA", userSample, at: "2026-11-27T04:06:28.378Z")
        XCTAssertEqual(m.plainLabel, "MIAM compressed message")
        XCTAssertEqual(value(m, "Label"), "H1/DF")
        XCTAssertEqual(value(m, "Route"), "KORD → EDDM")
        XCTAssertEqual(value(m, "Flight"), "DLH4C")
        XCTAssertEqual(value(m, "Report"), "Normal Landing Gear Retraction")
        let text = try XCTUnwrap(m.decodedText)
        XCTAssertTrue(text.hasPrefix("A350,000221,1,1,TB000000/REP020,01,03;H01,020,01,03,4000,00127,.D-AIXL,"))
        XCTAssertTrue(text.allSatisfy { $0.isASCII })
        let finnair = try message("MA", finnairGear)
        XCTAssertEqual(value(finnair, "Route"), "WSSS → EFHK")
        XCTAssertEqual(value(finnair, "Report"), "Normal Landing Gear Extension")
    }

    func testUncompressedAndIncompleteMIAM() throws {
        let plain = try message("MA", "T-2!<<+4/k&,Z:09q8!!,VF6q6_fO66KC|A350,000106,1,1,TB000000/REP502,41,00;POSDMU,040452,+413208,-0060377,011454,400/:")
        XCTAssertEqual(plain.plainLabel, "MIAM message")
        XCTAssertEqual(plain.decodedText, "A350,000106,1,1,TB000000/REP502,41,00;POSDMU,040452,+413208,-0060377,011454,400/:")
        // The first ACARS block only: the rest of the compressed body is missing, so nothing is shown.
        let cut = try message("MA", truncated)
        XCTAssertEqual(cut.plainLabel, "MIAM message (incomplete)")
        XCTAssertNil(cut.decodedText)
        XCTAssertEqual(try message("MA", "T.0&HDeF/icra;b';dzL,`1o|").plainLabel, "MIAM acknowledgement")
        XCTAssertEqual(try message("MA", #"TJj>+--*5jk\m@=TADFGPq@-F<"B!Y6Qc,,9Bq5Kp"#).plainLabel, "MIAM message (part)")
        // A changed character breaks the CRC: incomplete, never garbage.
        var bytes = Array(finnairGear.utf8)
        bytes[300] = bytes[300] == UInt8(ascii: "A") ? UInt8(ascii: "B") : UInt8(ascii: "A")
        XCTAssertNil(try message("MA", String(decoding: bytes, as: UTF8.self)).decodedText)
    }

    func testUnknownMessagesAreNotDecoded() throws {
        let m = try message("5Z", "OS KSMF/CHO0424")
        XCTAssertNil(m.summary)
        XCTAssertNil(m.decodedText)
        XCTAssertTrue(m.fields.isEmpty)
        XCTAssertEqual(m.plainLabel, "Airline ops")
    }
}
