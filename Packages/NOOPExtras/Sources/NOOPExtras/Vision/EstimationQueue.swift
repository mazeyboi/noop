import Foundation

/// Meal photos saved on the phone (downscaled JPEGs), uploaded to the server on sync.
public final class PhotoStore: @unchecked Sendable {
    public let directory: URL
    let store: ExtrasStore

    public init(directory: URL, store: ExtrasStore) throws {
        self.directory = directory
        self.store = store
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func defaultDirectory() throws -> URL {
        try ExtrasDatabase.defaultURL().deletingLastPathComponent().appendingPathComponent("Photos", isDirectory: true)
    }

    /// Saves a JPEG and returns its id (also the server's photo id).
    public func save(jpeg: Data) throws -> String {
        let id = UUID().uuidString.lowercased()
        try jpeg.write(to: url(id: id), options: .atomic)
        try store.addPhoto(id: id, fileName: "\(id).jpg")
        return id
    }

    public func url(id: String) -> URL { directory.appendingPathComponent("\(id).jpg") }

    public func data(id: String) -> Data? { try? Data(contentsOf: url(id: id)) }
}

extension ExtrasStore {
    func addPhoto(id: String, fileName: String) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO photo (id, fileName, uploaded, createdAt) VALUES (?, ?, 0, ?)",
                           arguments: [id, fileName, Date().timeIntervalSince1970])
        }
    }

    public func photosToUpload() throws -> [String] {
        try db.read { try String.fetchAll($0, sql: "SELECT id FROM photo WHERE NOT uploaded ORDER BY createdAt") }
    }

    public func markPhotoUploaded(id: String) throws {
        try db.write { try $0.execute(sql: "UPDATE photo SET uploaded = 1 WHERE id = ?", arguments: [id]) }
    }
}

/// Turns pending photo entries into logged entries, whenever a provider is set up and the phone is online.
public final class EstimationQueue: @unchecked Sendable {
    /// After this many retryable failures an entry waits for a tap on "retry".
    public static let maxAttempts = 8

    let store: ExtrasStore
    let photos: PhotoStore
    let provider: () -> FoodVisionProvider?
    let timeZone: TimeZone
    private let lock = NSLock()
    private var running = false

    public init(store: ExtrasStore, photos: PhotoStore, provider: @escaping () -> FoodVisionProvider?,
                timeZone: TimeZone = .current) {
        self.store = store; self.photos = photos; self.provider = provider; self.timeZone = timeZone
    }

    /// Estimates every pending entry it can. Returns how many were estimated. Never throws: failures are
    /// recorded on the entries themselves.
    @discardableResult
    public func runPending() async -> Int {
        guard lock.withLock({ () -> Bool in if running { return false }; running = true; return true }) else { return 0 }
        defer { lock.withLock { running = false } }

        guard let pending = try? store.pendingEntries().filter({ $0.attempts < Self.maxAttempts }),
              !pending.isEmpty else { return 0 }
        guard let provider = provider() else {
            for var e in pending where e.error != ProviderError.notConfigured.message {
                e.error = ProviderError.notConfigured.message
                try? store.save(e)
            }
            return 0
        }
        var done = 0
        for e in pending {
            guard let image = e.photoId.flatMap(photos.data(id:)) else {
                var f = e
                f.status = .failed
                f.error = "The photo is missing. Enter this meal manually."
                try? store.save(f)
                continue
            }
            let req = EstimateRequest(image: image, hint: e.hint, meal: e.meal, at: e.at, timeZone: timeZone)
            do {
                let est: FoodEstimate
                do {
                    est = try await provider.estimate(req)
                } catch ProviderError.malformed {
                    est = try await provider.estimate(req) // one immediate retry
                }
                if (try? store.applyEstimate(est, to: e.id, provider: provider.kind.rawValue, model: provider.model)) != nil {
                    done += 1
                }
            } catch let err as ProviderError {
                guard var f = try? store.entry(id: e.id), !f.deleted, f.status == .pending else { continue }
                f.error = err.message
                if err.isRetryable {
                    f.attempts += 1
                } else {
                    f.status = .failed
                }
                try? store.save(f)
                if err == .offline || err == .timeout { break }
            } catch {
                continue
            }
        }
        return done
    }

    /// "Tap to retry": back to pending with a fresh attempt budget.
    public func retry(entryId: String) throws {
        guard var e = try store.entry(id: entryId) else { return }
        e.status = .pending
        e.attempts = 0
        e.error = nil
        try store.save(e)
    }
}
