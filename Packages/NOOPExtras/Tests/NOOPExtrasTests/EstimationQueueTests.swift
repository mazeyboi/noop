import XCTest
@testable import NOOPExtras

final class StubProvider: FoodVisionProvider, @unchecked Sendable {
    let kind: ProviderKind = .anthropic
    let model = "stub-model"
    var results: [Result<FoodEstimate, ProviderError>]
    private(set) var calls = 0
    var onCall: ((Int) -> Void)?
    init(_ results: [Result<FoodEstimate, ProviderError>]) { self.results = results }
    func estimate(_ r: EstimateRequest) async throws -> FoodEstimate {
        calls += 1
        onCall?(calls)
        let r = results.isEmpty ? .failure(.server(500)) : results.removeFirst()
        return try r.get()
    }
}

final class EstimationQueueTests: XCTestCase {
    var store: ExtrasStore!
    var photos: PhotoStore!
    var tmp: URL!
    let est = FoodEstimate(items: [.init(name: "Pasta", grams: 300, kcal: 520, proteinG: 18)],
                           confidence: .medium, note: "Oil assumed.")

    override func setUpWithError() throws {
        store = try ExtrasStore(db: ExtrasDatabase.inMemory())
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        photos = try PhotoStore(directory: tmp, store: store)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func pendingPhoto(edited: Bool = false) throws -> FoodEntry {
        let id = try photos.save(jpeg: sampleJPEG)
        var e = FoodEntry.new(at: Date(), meal: .dinner, method: .photo_ai, status: .pending)
        e.photoId = id
        e.hint = "big plate"
        if edited {
            e.edited = true
            e.items = [EntryItem(name: "my own guess", grams: nil, nutrients: Nutrients(kcal: 700))]
        }
        try store.save(e)
        return e
    }

    func queue(_ p: StubProvider?) -> EstimationQueue {
        EstimationQueue(store: store, photos: photos, provider: { p })
    }

    func test_no_provider_keeps_pending_with_hint() async throws {
        let e = try pendingPhoto()
        let n = await queue(nil).runPending()
        XCTAssertEqual(n, 0)
        let after = try XCTUnwrap(store.entry(id: e.id))
        XCTAssertEqual(after.status, .pending)
        XCTAssertEqual(after.error, "Set up an AI provider in Food settings")
        XCTAssertEqual(after.attempts, 0)
    }

    func test_success_logs_entry_with_provenance() async throws {
        let e = try pendingPhoto()
        let p = StubProvider([.success(est)])
        let n = await queue(p).runPending()
        XCTAssertEqual(n, 1)
        let after = try XCTUnwrap(store.entry(id: e.id))
        XCTAssertEqual(after.status, .logged)
        XCTAssertEqual(after.totals.kcal, 520)
        XCTAssertEqual(after.aiOriginal, est)
        XCTAssertEqual(after.aiProvider, "anthropic")
        XCTAssertEqual(after.aiModel, "stub-model")
        XCTAssertEqual(after.method, .photo_ai)
        XCTAssertEqual(after.photoId, e.photoId)
    }

    func test_malformed_retried_once_then_pending() async throws {
        let e = try pendingPhoto()
        let p = StubProvider([.failure(.malformed("x")), .failure(.malformed("y"))])
        _ = await queue(p).runPending()
        XCTAssertEqual(p.calls, 2)
        let after = try XCTUnwrap(store.entry(id: e.id))
        XCTAssertEqual(after.status, .pending)
        XCTAssertEqual(after.attempts, 1)
        XCTAssertNotNil(after.error)
    }

    func test_malformed_then_ok_on_retry() async throws {
        let e = try pendingPhoto()
        let p = StubProvider([.failure(.malformed("x")), .success(est)])
        let ran = await queue(p).runPending()
        XCTAssertEqual(ran, 1)
        XCTAssertEqual(try store.entry(id: e.id)?.status, .logged)
    }

    func test_rate_limited_stays_pending() async throws {
        let e = try pendingPhoto()
        _ = await queue(StubProvider([.failure(.rateLimited)])).runPending()
        let after = try XCTUnwrap(store.entry(id: e.id))
        XCTAssertEqual(after.status, .pending)
        XCTAssertEqual(after.attempts, 1)
        XCTAssertEqual(after.error, ProviderError.rateLimited.message)
    }

    func test_refusal_marks_failed() async throws {
        let e = try pendingPhoto()
        _ = await queue(StubProvider([.failure(.refused("No food found in the photo."))])).runPending()
        let after = try XCTUnwrap(store.entry(id: e.id))
        XCTAssertEqual(after.status, .failed)
        XCTAssertTrue(after.error?.contains("Tap to retry") == true)
        XCTAssertEqual(try store.dayTotals(on: Date()).pendingCount, 1)
    }

    func test_edited_entry_not_overwritten() async throws {
        let e = try pendingPhoto(edited: true)
        _ = await queue(StubProvider([.success(est)])).runPending()
        let after = try XCTUnwrap(store.entry(id: e.id))
        XCTAssertEqual(after.totals.kcal, 700)
        XCTAssertEqual(after.aiOriginal, est)
    }

    func test_gives_up_after_max_attempts_until_retry() async throws {
        var e = try pendingPhoto()
        e.attempts = EstimationQueue.maxAttempts
        try store.save(e)
        let p = StubProvider([.success(est)])
        let ran = await queue(p).runPending()
        XCTAssertEqual(ran, 0)
        XCTAssertEqual(p.calls, 0)
        try queue(p).retry(entryId: e.id)
        let ranAfterRetry = await queue(p).runPending()
        XCTAssertEqual(ranAfterRetry, 1)
    }

    func test_offline_stops_the_run() async throws {
        _ = try pendingPhoto(); _ = try pendingPhoto()
        let p = StubProvider([.failure(.offline), .success(est)])
        let ran = await queue(p).runPending()
        XCTAssertEqual(ran, 0)
        XCTAssertEqual(p.calls, 1)
    }

    func test_photo_store_round_trip_and_upload_list() throws {
        let id = try photos.save(jpeg: sampleJPEG)
        XCTAssertEqual(photos.data(id: id), sampleJPEG)
        XCTAssertEqual(try store.photosToUpload(), [id])
        try store.markPhotoUploaded(id: id)
        XCTAssertEqual(try store.photosToUpload(), [])
        XCTAssertNotNil(id.range(of: #"^[A-Za-z0-9_-]{1,100}$"#, options: .regularExpression))
    }
}
