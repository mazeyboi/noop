import GRDB
import WhoopStore
import XCTest
@testable import NOOPExtras

/// Runs NOOPDataReader against a database created by upstream's CURRENT WhoopStore migrator. If upstream
/// renames or drops a column the reader uses, these tests fail in the fork's CI before a release ships.
final class NOOPDataReaderTests: XCTestCase {
    var dir: URL!
    var dbURL: URL!
    var defaults: UserDefaults!
    var suite: String!
    /// Stands in for NOOP itself, which keeps its database open while extras reads it.
    var writer: DatabaseQueue?

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("noop-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("whoop.sqlite")
        suite = "noop-reader-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        writer = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Upstream's migrator creates the schema; rows go in with plain SQL.
    func makeFixture(_ sql: String) async throws {
        _ = try await WhoopStore(path: dbURL.path)
        let q = try DatabaseQueue(path: dbURL.path)
        try await q.write { try $0.execute(sql: sql) }
        writer = q
    }

    func reader() -> NOOPDataReader { NOOPDataReader(databaseURL: dbURL, defaults: defaults) }

    func test_reader_missing_database_is_empty() throws {
        let r = NOOPDataReader(databaseURL: dir.appendingPathComponent("nope.sqlite"), defaults: defaults)
        for kind in [SyncKind.sleep_sessions, .daily_metrics, .workouts, .noop_intake] {
            XCTAssertEqual(try r.records(kind: kind), [])
        }
        XCTAssertEqual(try r.hrDevices(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("nope.sqlite").path))
    }

    func test_reads_sleep_daily_workouts_from_upstream_schema() async throws {
        try await makeFixture("""
        INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON, motionJSON)
          VALUES ('whoop-1', 1794960000, 1794988800, 0.91, 52, 61.5, '{"deep":80,"rem":95}', '[1,2,3]');
        INSERT INTO dailyMetric (deviceId, day, totalSleepMin, recovery, strain, restingHr, avgHrv, steps)
          VALUES ('whoop-1', '2026-11-17', 450, 71, 9.8, 52, 61.5, 8123);
        INSERT INTO workout (deviceId, startTs, endTs, sport, source, durationS, energyKcal, avgHr, maxHr, strain, zonesJSON)
          VALUES ('whoop-1', 1795010000, 1795013600, 'running', 'strap', 3600, 610, 148, 181, 12.4, '[60,300,900,1800,540]');
        """)
        let r = reader()

        let sleep = try r.records(kind: .sleep_sessions)
        XCTAssertEqual(sleep.count, 1)
        XCTAssertEqual(sleep[0].id, "whoop-1|1794960000")
        XCTAssertEqual(sleep[0].data["start_at"], .string(ExtrasCodec.wireDate(Date(timeIntervalSince1970: 1794960000))))
        XCTAssertEqual(sleep[0].data["end_at"], .string(ExtrasCodec.wireDate(Date(timeIntervalSince1970: 1794988800))))
        XCTAssertEqual(sleep[0].data["restingHr"], .number(52))
        XCTAssertEqual(sleep[0].data["stages"], .object(["deep": .number(80), "rem": .number(95)]))
        XCTAssertNil(sleep[0].data["motionJSON"], "big per-epoch blobs stay on the phone")
        XCTAssertEqual(sleep[0].data["device_id"], .string("whoop-1"))

        let daily = try r.records(kind: .daily_metrics)
        XCTAssertEqual(daily.map(\.id), ["whoop-1|2026-11-17"])
        XCTAssertEqual(daily[0].data["day"], .string("2026-11-17"))
        XCTAssertEqual(daily[0].data["recovery"], .number(71))
        XCTAssertEqual(daily[0].data["steps"], .number(8123))

        let workouts = try r.records(kind: .workouts)
        XCTAssertEqual(workouts.map(\.id), ["whoop-1|1795010000|running"])
        XCTAssertEqual(workouts[0].data["sport"], .string("running"))
        XCTAssertEqual(workouts[0].data["zones"], .array([60, 300, 900, 1800, 540].map { .number($0) }))
        XCTAssertNotNil(workouts[0].data["start_at"]?.stringValue)
    }

    func test_hr_minute_aggregates() async throws {
        try await makeFixture("""
        INSERT INTO hrSample (deviceId, ts, bpm) VALUES
          ('whoop-1', 1794999960, 60), ('whoop-1', 1794999970, 62), ('whoop-1', 1794999980, 70),
          ('whoop-1', 1795000040, 80),
          ('polar-2', 1794999960, 100);
        """)
        let r = reader()
        XCTAssertEqual(try r.hrDevices(), ["polar-2", "whoop-1"])
        let start = Date(timeIntervalSince1970: 1794960000), end = Date(timeIntervalSince1970: 1795046400)
        XCTAssertEqual(try r.hrFirstDay(deviceId: "whoop-1"), Date(timeIntervalSince1970: 1794999960))
        let fp = try XCTUnwrap(r.hrFingerprint(deviceId: "whoop-1", from: start, to: end))
        XCTAssertNil(try r.hrFingerprint(deviceId: "whoop-1", from: end, to: end.addingTimeInterval(86400)))
        let mins = try r.hrMinutes(deviceId: "whoop-1", from: start, to: end)
        XCTAssertEqual(mins.count, 2)
        let m0 = 1794999960
        XCTAssertEqual(mins[0].id, "whoop-1|\(m0)")
        XCTAssertEqual(mins[0].data["at"], .string(ExtrasCodec.wireDate(Date(timeIntervalSince1970: Double(m0)))))
        XCTAssertEqual(mins[0].data["bpm"], .number(64))
        XCTAssertEqual(mins[0].data["min"], .number(60))
        XCTAssertEqual(mins[0].data["max"], .number(70))
        XCTAssertEqual(mins[0].data["n"], .number(3))
        // fingerprint changes when a late sample arrives
        let q = try XCTUnwrap(writer)
        try await q.write { try $0.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('whoop-1', 1795000050, 90)") }
        XCTAssertNotEqual(try r.hrFingerprint(deviceId: "whoop-1", from: start, to: end), fp)
    }

    func test_intake_from_defaults_and_metric_series() async throws {
        try await makeFixture("""
        INSERT INTO metricSeries (deviceId, day, key, value) VALUES
          ('hydration', '2026-11-17', 'hydration', 1500), ('hydration', '2026-11-17', 'hydrationImported', 250),
          ('hydration', '2026-11-17', 'somethingElse', 1);
        """)
        let at = Date(timeIntervalSince1970: 1795000000)
        let intakes = [["id": "7A1C1E2B-0000-4000-8000-000000000001", "at": at.timeIntervalSinceReferenceDate, "mg": 95] as [String: Any],
                       ["id": "7A1C1E2B-0000-4000-8000-000000000002", "at": at.timeIntervalSinceReferenceDate + 3600,
                        "externalId": "HK-1"]]
        defaults.set(try JSONSerialization.data(withJSONObject: intakes), forKey: "caffeine.intakes")
        let recs = try reader().records(kind: .noop_intake)
        let caffeine = recs.filter { $0.id.hasPrefix("caffeine|") }
        XCTAssertEqual(caffeine.count, 2)
        let first = try XCTUnwrap(caffeine.first { $0.id == "caffeine|7A1C1E2B-0000-4000-8000-000000000001" })
        XCTAssertEqual(first.data["mg"], .number(95))
        XCTAssertEqual(first.data["at"], .string(ExtrasCodec.wireDate(at)))
        XCTAssertEqual(first.data["kind"], .string("caffeine"))
        let second = try XCTUnwrap(caffeine.first { $0.id.hasSuffix("0002") })
        XCTAssertEqual(second.data["mg"], .null)
        XCTAssertEqual(second.data["source"], .string("apple_health"))
        let water = recs.filter { $0.id.hasPrefix("hydration|") }.sorted { $0.id < $1.id }
        XCTAssertEqual(water.map(\.id), ["hydration|hydration|2026-11-17|hydration", "hydration|hydration|2026-11-17|hydrationImported"])
        XCTAssertEqual(water[0].data["ml"], .number(1500))
        XCTAssertNotNil(water[0].data["at"]?.stringValue.flatMap(ExtrasCodec.parseWireDate))
    }
}
