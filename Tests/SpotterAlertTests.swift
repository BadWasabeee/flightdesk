import XCTest

final class SpotterAlertTests: XCTestCase {

    private func flight(hex: String = "abc123", callsign: String = "DAL1342", reg: String = "N123DL",
                        type: String = "B738", alt: Int = 12_000, dist: Double = 4) -> Flight {
        let json = """
        {"hex":"\(hex)","flight":"\(callsign)","r":"\(reg)","t":"\(type)","alt_baro":\(alt),"gs":300,"track":90,
         "lat":39.7,"lon":-104.9,"dst":\(dist),"dir":45,"baro_rate":0}
        """
        return Flight(adsb: try! JSONDecoder().decode(ADSBAircraft.self, from: Data(json.utf8)))!
    }

    private let csv = #"""
    $ICAO,$Registration,$Operator,$Type,$ICAO Type,#CMPG,$Tag 1,$#Tag 2,$#Tag 3,Category,$#Link
    AE07E1,05-5140,United States Air Force,Boeing C-17A Globemaster III,C17,Mil,Moose,Globemaster,Cargo,USAF,https://w.wiki/x
    AB4C7E,N827ST,MI State Police,Bell UH-1H Iroquois,UH1,Pol,Police Squad,"Los, Judis","Say ""Hi""",Police Forces,"https://a.b/0,4643"
    4CA123,EI-ABC,Somebody,Supermarine Spitfire,SPIT,Civ,Warbird,,,Historic,\#r
    ZZZZZZ,bad,row,,,,,,,,
    """#

    private var db: PlaneAlertDB { PlaneAlertDB(csv: Data(csv.utf8))! }
    private func settings(_ change: (inout SpotterSettings) -> Void) -> SpotterSettings {
        var s = SpotterSettings()
        s.emergencies = false
        change(&s)
        return s
    }

    // MARK: CSV

    func testCSVHandlesQuotesEscapesAndCRLF() {
        let rows = CSV.parse(Data("a,\"b,c\",\"d \"\"e\"\"\"\r\n\n,x,\r\nlast".utf8))
        XCTAssertEqual(rows, [["a", "b,c", "d \"e\""], ["", "x", ""], ["last"]])
    }

    func testPlaneAlertDBIndexesByLowercaseHex() {
        let db = self.db
        XCTAssertEqual(db.entries.count, 3, "invalid hex rows are skipped")
        let c17 = db["AE07E1"]
        XCTAssertEqual(c17?.hex, "ae07e1")
        XCTAssertEqual(c17?.group, "Mil")
        XCTAssertEqual(c17?.icaoType, "C17")
        XCTAssertEqual(c17?.category, "USAF")
        XCTAssertEqual(c17?.tags, ["Moose", "Globemaster", "Cargo"])
        let police = db["ab4c7e"]
        XCTAssertEqual(police?.tags, ["Police Squad", "Los, Judis", "Say \"Hi\""])
        XCTAssertEqual(db["4ca123"]?.tags, ["Warbird"])
        XCTAssertEqual(db.groupCounts, ["Mil": 1, "Pol": 1, "Civ": 1])
        XCTAssertEqual(Set(db.categories.map(\.name)), ["USAF", "Police Forces", "Historic"])
    }

    func testPlaneAlertDBRejectsMissingHeader() {
        XCTAssertNil(PlaneAlertDB(csv: Data("foo,bar\n1,2".utf8)))
    }

    // MARK: Settings decoding

    func testSettingsDecodeToleratesMissingAndBadKeys() throws {
        let json = """
        {"heavies":true,"proximityNM":"oops","watchlist":[{"id":"\(UUID().uuidString)","kind":"type","value":"A388"},{"kind":"nope"}],
         "quietHours":{"enabled":true}}
        """
        let s = SpotterSettings.decode(Data(json.utf8))
        XCTAssertTrue(s.heavies)
        XCTAssertTrue(s.emergencies, "missing keys use defaults")
        XCTAssertEqual(s.proximityNM, 2)
        XCTAssertEqual(s.watchlist.map(\.value), ["A388"], "bad items are dropped individually")
        XCTAssertTrue(s.quietHours.enabled)
        XCTAssertEqual(s.quietHours.start, 22 * 60)
        XCTAssertEqual(SpotterSettings.decode(nil), SpotterSettings())
        XCTAssertEqual(SpotterSettings.decode(try JSONEncoder().encode(s)), s)
    }

    // MARK: Watchlist

    func testWatchItemValidation() {
        XCTAssertEqual(WatchItem.normalize(" AE07E1 ", as: .hex), "ae07e1")
        XCTAssertNil(WatchItem.normalize("AE07EG", as: .hex))
        XCTAssertNil(WatchItem.normalize("AE07E", as: .hex))
        XCTAssertEqual(WatchItem.normalize("b748", as: .type), "B748")
        XCTAssertNil(WatchItem.normalize("7478", as: .type))
        XCTAssertNil(WatchItem.normalize("B7478", as: .type))
        XCTAssertEqual(WatchItem.normalize("dal", as: .callsign), "DAL")
        XCTAssertNil(WatchItem.normalize("DAL 1", as: .callsign))
        XCTAssertEqual(WatchItem.normalize("g-eupt", as: .registration), "G-EUPT")
        XCTAssertNil(WatchItem.normalize("G_EUPT", as: .registration))
        XCTAssertNil(WatchItem.normalize("", as: .registration))
    }

    func testWatchItemMatching() {
        let f = flight(hex: "ae07e1", callsign: "RCH123", reg: "05-5140", type: "C17")
        XCTAssertTrue(WatchItem(kind: .hex, value: "ae07e1").matches(f))
        XCTAssertTrue(WatchItem(kind: .type, value: "C17").matches(f))
        XCTAssertTrue(WatchItem(kind: .callsign, value: "RCH").matches(f))
        XCTAssertFalse(WatchItem(kind: .callsign, value: "DAL").matches(f))
        XCTAssertTrue(WatchItem(kind: .registration, value: "055140").matches(f), "dashes are ignored")
        XCTAssertFalse(WatchItem(kind: .type, value: "C130").matches(f))
    }

    // MARK: Rules

    func testEmergencySquawkUsesSeam() {
        let f = flight()
        let s = SpotterSettings()
        XCTAssertTrue(SpotterEngine.evaluate([f], settings: s, db: nil, squawk: { _ in nil }).isEmpty)
        XCTAssertTrue(SpotterEngine.evaluate([f], settings: s, db: nil, squawk: { _ in "1200" }).isEmpty)
        let a = SpotterEngine.evaluate([f], settings: s, db: nil, squawk: { _ in "7700" })
        XCTAssertEqual(a.map(\.rule), [.emergency])
        XCTAssertEqual(a.first?.label, "Emergency · squawk 7700")
        XCTAssertEqual(SpotterEngine.evaluate([f], settings: s, db: nil, squawk: { _ in "7600" }).first?.label,
                       "Radio failure · squawk 7600")
    }

    func testInterestingByGroupOrCategory() {
        let c17 = flight(hex: "ae07e1", type: "C17"), spit = flight(hex: "4ca123", type: "SPIT"), other = flight(hex: "111111")
        var s = settings { $0.interesting = true }
        var hits = SpotterEngine.evaluate([c17, spit, other], settings: s, db: db, squawk: { _ in nil })
        XCTAssertEqual(hits.map(\.flight.id), ["ae07e1"], "default group is Mil")
        XCTAssertEqual(hits.first?.label, "Military")

        s.interestingCategories = ["Historic"]
        hits = SpotterEngine.evaluate([c17, spit, other], settings: s, db: db, squawk: { _ in nil })
        XCTAssertEqual(hits.map(\.label), ["Military", "Historic"])

        s.interestingGroups = []
        s.interestingCategories = []
        XCTAssertFalse(s.activeRules.contains(.interesting), "nothing selected means the rule is inactive")
        XCTAssertTrue(SpotterEngine.evaluate([c17], settings: s, db: db, squawk: { _ in nil }).isEmpty)
    }

    func testHeavyProximityAndPriorityOrder() {
        let s = settings {
            $0.heavies = true
            $0.proximity = true
            $0.proximityNM = 3
            $0.watchlist = [WatchItem(kind: .type, value: "B748")]
        }
        let jumbo = flight(hex: "aaaaaa", type: "B748", dist: 2)
        let a = SpotterEngine.evaluate([jumbo, flight(hex: "bbbbbb", type: "B738", dist: 10)],
                                       settings: s, db: nil, squawk: { _ in nil })
        XCTAssertEqual(a.map(\.rule), [.watchlist, .heavy, .proximity])
        XCTAssertEqual(a.map(\.label), ["Watchlist · B748", "Wide-body", "Close approach"], "the watchlist label names the entry")
        XCTAssertTrue(a.allSatisfy { $0.flight.id == "aaaaaa" })
    }

    func testWatchlistDisabledOrEmptyIsInactive() {
        var s = settings { $0.watchlist = [WatchItem(kind: .type, value: "B748")] }
        XCTAssertTrue(s.activeRules.contains(.watchlist))
        s.watchlistEnabled = false
        XCTAssertFalse(s.activeRules.contains(.watchlist))
        XCTAssertTrue(settings { _ in }.activeRules.isEmpty)
    }

    // MARK: De-duplication

    func testLedgerOnePerAircraftAndWindow() {
        let s = settings { $0.heavies = true; $0.proximity = true; $0.proximityNM = 5 }
        let f = flight(type: "A388", dist: 1)
        let candidates = SpotterEngine.evaluate([f], settings: s, db: nil, squawk: { _ in nil })
        XCTAssertEqual(candidates.count, 2)

        var ledger = AlertLedger()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ledger.admit(candidates, now: t0).map(\.rule), [.heavy], "one notification per aircraft")
        XCTAssertTrue(ledger.isRecent(.proximity, hex: f.id, now: t0), "lesser matches are recorded too")
        XCTAssertTrue(ledger.admit(candidates, now: t0.addingTimeInterval(3600)).isEmpty)
        XCTAssertEqual(ledger.admit(candidates, now: t0.addingTimeInterval(AlertLedger.window + 1)).count, 1)
    }

    func testLedgerNewRuleStillFiresAndLimitDefersRest() {
        var ledger = AlertLedger()
        let t0 = Date(timeIntervalSince1970: 0)
        let f = flight()
        _ = ledger.admit([SpotterAlert(flight: f, rule: .proximity, label: "", entry: nil)], now: t0)
        let emergency = SpotterAlert(flight: f, rule: .emergency, label: "", entry: nil)
        XCTAssertEqual(ledger.admit([emergency], now: t0.addingTimeInterval(60)).map(\.rule), [.emergency])

        let many = (0..<5).map { SpotterAlert(flight: flight(hex: String(format: "c0000%d", $0), dist: Double(5 - $0)),
                                              rule: .heavy, label: "", entry: nil) }
        let first = ledger.admit(many, now: t0, limit: 3)
        XCTAssertEqual(first.map(\.flight.id), ["c00004", "c00003", "c00002"], "nearest first")
        XCTAssertEqual(ledger.admit(many, now: t0, limit: 3).map(\.flight.id), ["c00001", "c00000"])
    }

    func testMuteSilencesEveryRuleUntilItExpires() {
        var ledger = AlertLedger()
        let t0 = Date(timeIntervalSince1970: 0)
        let f = flight(hex: "ABC123")
        let alerts = [SpotterAlert(flight: f, rule: .emergency, label: "", entry: nil),
                      SpotterAlert(flight: f, rule: .heavy, label: "", entry: nil)]
        ledger.mute(hex: "ABC123", now: t0)
        XCTAssertTrue(ledger.isMuted(hex: "abc123", now: t0.addingTimeInterval(3600)))
        XCTAssertEqual(ledger.mutedCount(now: t0), 1)
        XCTAssertTrue(ledger.admit(alerts, now: t0.addingTimeInterval(3600)).isEmpty, "muted aircraft never alert")
        let later = t0.addingTimeInterval(AlertLedger.muteDuration + 1)
        XCTAssertFalse(ledger.isMuted(hex: "abc123", now: later))
        ledger.prune(now: later)
        XCTAssertTrue(ledger.muted.isEmpty, "expired mutes are pruned")
        XCTAssertEqual(ledger.admit(alerts, now: later).map(\.rule), [.emergency])

        ledger.mute(hex: "abc123", now: later)
        ledger.unmuteAll()
        XCTAssertEqual(ledger.mutedCount(now: later), 0)
    }

    func testLedgerDecodesDataWrittenBeforeMutes() throws {
        let old = try JSONEncoder().encode(["sent": ["heavy|abc123": Date(timeIntervalSince1970: 0)]])
        let ledger = try JSONDecoder().decode(AlertLedger.self, from: old)
        XCTAssertTrue(ledger.isRecent(.heavy, hex: "abc123", now: Date(timeIntervalSince1970: 60)))
        XCTAssertTrue(ledger.muted.isEmpty)
        var muted = ledger
        muted.mute(hex: "abc123", now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(try JSONDecoder().decode(AlertLedger.self, from: JSONEncoder().encode(muted)), muted)
    }

    func testLedgerPruneAndCodable() throws {
        var ledger = AlertLedger()
        let t0 = Date(timeIntervalSince1970: 0)
        ledger.record(.heavy, hex: "ABC123", now: t0)
        XCTAssertTrue(ledger.isRecent(.heavy, hex: "abc123", now: t0))
        let decoded = try JSONDecoder().decode(AlertLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(decoded, ledger)
        ledger.prune(now: t0.addingTimeInterval(AlertLedger.window))
        XCTAssertTrue(ledger.sent.isEmpty)
    }

    // MARK: Quiet hours

    private func at(_ h: Int, _ m: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: h, minute: m))!
    }
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    func testQuietHoursWrapMidnight() {
        var q = QuietHours()
        XCTAssertFalse(q.isQuiet(at: at(23), calendar: utc), "disabled by default")
        q.enabled = true                                   // 22:00–07:00
        XCTAssertTrue(q.isQuiet(at: at(22), calendar: utc))
        XCTAssertTrue(q.isQuiet(at: at(3), calendar: utc))
        XCTAssertTrue(q.isQuiet(at: at(6, 59), calendar: utc))
        XCTAssertFalse(q.isQuiet(at: at(7), calendar: utc))
        XCTAssertFalse(q.isQuiet(at: at(12), calendar: utc))
    }

    func testQuietHoursSameDayAndEmpty() {
        var q = QuietHours()
        q.enabled = true
        q.start = 9 * 60
        q.end = 17 * 60 + 30
        XCTAssertTrue(q.isQuiet(at: at(17, 29), calendar: utc))
        XCTAssertFalse(q.isQuiet(at: at(17, 30), calendar: utc))
        XCTAssertFalse(q.isQuiet(at: at(8), calendar: utc))
        q.end = q.start
        XCTAssertFalse(q.isQuiet(at: at(9), calendar: utc))
    }

    func testQuietHoursLetEmergenciesThrough() {
        var q = QuietHours()
        q.enabled = true
        let f = flight()
        let alerts = [SpotterAlert(flight: f, rule: .emergency, label: "", entry: nil),
                      SpotterAlert(flight: f, rule: .heavy, label: "", entry: nil)]
        XCTAssertEqual(SpotterEngine.applyQuietHours(alerts, q, at: at(23), calendar: utc).map(\.rule), [.emergency])
        XCTAssertEqual(SpotterEngine.applyQuietHours(alerts, q, at: at(12), calendar: utc).count, 2)
        q.allowEmergencies = false
        XCTAssertTrue(SpotterEngine.applyQuietHours(alerts, q, at: at(23), calendar: utc).isEmpty)
    }

    // MARK: Text

    func testNotificationText() {
        let f = flight(hex: "ae07e1", callsign: "RCH123", reg: "05-5140", type: "C17", alt: 24_000, dist: 2.5)
        let entry = db["ae07e1"]
        let a = SpotterAlert(flight: f, rule: .interesting, label: "Military", entry: entry)
        XCTAssertEqual(a.title, "Boeing C-17A Globemaster III overhead")
        XCTAssertEqual(a.subtitle, "Military")
        var o = DisplayOptions()                            // LED style by default; alerts always use standard text
        XCTAssertEqual(a.body(display: o), "RCH123 · 05-5140 · United States Air Force\n\(24_000.formatted()) ft · 2.5 nm NE")
        o.units = .metric
        XCTAssertTrue(a.body(display: o).hasSuffix("4.6 km NE"))
        let far = SpotterAlert(flight: flight(type: "", dist: 9), rule: .proximity, label: "Close approach", entry: nil)
        XCTAssertEqual(far.title, "Aircraft nearby")
        XCTAssertEqual(far.subtitle, "Close approach")
        let mayday = SpotterAlert(flight: flight(type: "B738", dist: 2), rule: .emergency, label: "Emergency · squawk 7700", entry: nil)
        XCTAssertEqual(mayday.title, "Emergency · squawk 7700", "emergencies lead with the squawk")
        XCTAssertEqual(mayday.subtitle, "B738 overhead")
    }

    func testWatchKindCopyIsComplete() {
        for k in WatchItem.Kind.allCases {
            XCTAssertFalse(k.title.isEmpty)
            XCTAssertFalse(k.symbol.isEmpty)
            XCTAssertTrue(k.explanation.hasSuffix("."), "\(k) explanation is a sentence")
            XCTAssertTrue(k.validationHint.hasSuffix("."), "\(k) hint is a sentence")
            XCTAssertNil(WatchItem.normalize("!!", as: k), "\(k) rejects punctuation")
        }
    }

    func testMenuBarReadoutPicksNearestAirline() {
        let ga = flight(hex: "000001", callsign: "N123AB", dist: 1)
        let airline = flight(hex: "000002", callsign: "DAL1342", dist: 4)
        let farther = flight(hex: "000003", callsign: "UAL1", dist: 8)
        XCTAssertEqual(MenuBarReadout.text(flights: [farther, ga, airline], display: DisplayOptions()), "DAL1342 · 4.0 nm")
        XCTAssertNil(MenuBarReadout.text(flights: [ga], display: DisplayOptions()))
        var enriched = airline
        enriched.route = RouteInfo(flightNo: "DL1342", from: Airport(code: "A", city: "", lat: 0, lon: 0),
                                   to: Airport(code: "B", city: "", lat: 0, lon: 0))
        XCTAssertEqual(MenuBarReadout.text(flights: [airline], known: [enriched], display: DisplayOptions()), "DL1342 · 4.0 nm")
    }
}
