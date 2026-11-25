#if os(iOS)
import Foundation
import NOOPExtras
import SwiftUI
import UIKit

/// The food log's shared state, owned by the app for its whole life.
@MainActor
public final class ExtrasApp: ObservableObject {
    public static let shared = ExtrasApp()

    @Published public private(set) var selection = DaySelection(now: Date())
    public var day: Date { selection.day }
    @Published public private(set) var entries: [FoodEntry] = []
    @Published public private(set) var totals = DayTotals(logged: .zero, pendingCount: 0)
    @Published public private(set) var targets: Targets?
    @Published public private(set) var lastSync: SyncReport?
    @Published public private(set) var syncing = false
    @Published public private(set) var estimating = false
    @Published public var banner: String?
    /// The last deleted entry, offered for undo on the food screen.
    @Published public private(set) var undoable: FoodEntry?
    public let startupError: String?

    let store: ExtrasStore!
    let photos: PhotoStore!
    let secrets: SecretStore = KeychainSecretStore()
    let transport = URLSessionTransport.ephemeral()
    private(set) var queue: EstimationQueue!

    private init() {
        var error: String?
        var store: ExtrasStore?
        var photos: PhotoStore?
        do {
            let s = try ExtrasStore(db: ExtrasDatabase.open(at: ExtrasDatabase.defaultURL()))
            store = s
            photos = try PhotoStore(directory: PhotoStore.defaultDirectory(), store: s)
        } catch let e {
            error = "The food log couldn't open its database: \(e.localizedDescription)"
        }
        self.store = store
        self.photos = photos
        self.startupError = error
        if let store, let photos {
            let secrets = self.secrets, transport = self.transport
            queue = EstimationQueue(store: store, photos: photos, provider: {
                ProviderFactory.make(settings: ProviderSettings.load(from: try? store.kv(ProviderSettings.kvKey)),
                                     secrets: secrets, transport: transport)
            })
            reload()
        }
    }

    var ready: Bool { store != nil }

    // MARK: lifecycle

    /// Called by the app when it comes to the foreground: estimate waiting photos, then sync.
    public func appBecameActive() {
        guard ready else { return }
        refreshDay()
        Task {
            await estimatePending()
            await sync(force: false)
        }
    }

    /// Follows "today" across midnight (NOOP stays alive in the background for days).
    public func refreshDay() {
        var s = selection
        s.refresh(now: Date())
        if s != selection { selection = s; reload() }
    }

    public func shiftDay(_ n: Int) {
        selection.shift(by: n, now: Date())
        reload()
    }

    public func reload() {
        guard let store else { return }
        entries = (try? store.entries(on: day)) ?? []
        totals = (try? store.dayTotals(on: day)) ?? DayTotals(logged: .zero, pendingCount: 0)
        targets = try? store.targets()
    }

    public func estimatePending() async {
        guard let queue else { return }
        estimating = true
        await queue.runPending()
        estimating = false
        reload()
    }

    // MARK: sync

    var syncConfig: SyncConfig {
        guard let store else { return SyncConfig(token: nil) }
        return SyncConfig.load(store: store, secrets: secrets)
    }

    func engine() -> SyncEngine {
        let reader = NOOPDataReader.defaultURL().map { NOOPDataReader(databaseURL: $0) }
        return SyncEngine(store: store, api: SyncAPI(config: syncConfig, transport: transport), reader: reader, photos: photos)
    }

    public func sync(force: Bool) async {
        guard ready, !syncing else { return }
        syncing = true
        let report = await engine().syncAll(force: force)
        syncing = false
        if !report.skipped { lastSync = report }
        reload()
    }

    /// Sends this phone's unsynced changes first, so restoring never throws away a meal.
    func restore() async -> String {
        await sync(force: true)
        do {
            let n = try await engine().restore(force: false)
            reload()
            return "Restored \(n) records from the server."
        } catch SyncError.localChanges {
            let why = lastSync?.error?.message ?? ""
            return "Couldn't send this phone's unsynced changes first, so nothing was replaced. \(why)"
        } catch let e as SyncError {
            return e.message
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: provider

    var providerSettings: ProviderSettings? {
        get { store.flatMap { ProviderSettings.load(from: try? $0.kv(ProviderSettings.kvKey)) } }
        set {
            try? store?.setKV(ProviderSettings.kvKey, newValue?.json)
            objectWillChange.send()
        }
    }

    func provider() -> FoodVisionProvider? {
        ProviderFactory.make(settings: providerSettings, secrets: secrets, transport: transport)
    }

    // MARK: logging

    func save(_ entry: FoodEntry) {
        undoable = nil
        do { try store.save(entry) } catch { banner = "Couldn't save: \(error.localizedDescription)" }
        reload()
    }

    func delete(_ entry: FoodEntry) {
        do {
            try store.deleteEntry(id: entry.id)
            undoable = entry
        } catch { banner = "Couldn't delete: \(error.localizedDescription)" }
        reload()
    }

    func undoDelete() {
        guard let e = undoable else { return }
        undoable = nil
        do { try store.undeleteEntry(id: e.id) } catch { banner = "Couldn't undo: \(error.localizedDescription)" }
        reload()
    }

    /// When the last complete sync finished (kept across app restarts).
    var lastSyncSuccess: Date? {
        guard let store else { return nil }
        return (try? store.kv(SyncEngine.lastSuccessKey)).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    /// Saves the photo as a pending entry right away (nothing is lost offline), then tries to estimate it.
    func logPhoto(_ image: UIImage, hint: String, meal: MealType, at: Date) async -> FoodEntry? {
        guard let jpeg = ImageTools.downscaledJPEG(image) else { banner = "Couldn't read that photo."; return nil }
        do {
            let photoId = try photos.save(jpeg: jpeg)
            var e = FoodEntry.new(at: at, meal: meal, method: .photo_ai, status: .pending)
            e.photoId = photoId
            e.hint = hint.isEmpty ? nil : hint
            try store.save(e)
            reload()
            // This photo first (a backlog pass may be running), then anything else waiting.
            estimating = true
            await queue.estimate(entryId: e.id)
            estimating = false
            reload()
            Task { await estimatePending() }
            return try store.entry(id: e.id)
        } catch {
            banner = "Couldn't save the photo: \(error.localizedDescription)"
            return nil
        }
    }

    func retry(_ entry: FoodEntry) async {
        try? queue.retry(entryId: entry.id)
        await estimatePending()
    }

    func photo(for entry: FoodEntry) -> UIImage? {
        entry.photoId.flatMap { photos.data(id: $0) }.flatMap(UIImage.init(data:))
    }

    func copyMeal(_ meal: MealType, fromDaysAgo n: Int) {
        let cal = Calendar.current
        guard let from = cal.date(byAdding: .day, value: -n, to: day) else { return }
        let at = logTime
        let copied = (try? store.copyMeal(from: from, meal: meal, to: at)) ?? []
        banner = copied.isEmpty ? "Nothing logged for \(meal.title.lowercased()) that day." : nil
        reload()
    }

    /// The time to log at for the selected day: now if it's today, else noon that day.
    var logTime: Date { selection.logTime(now: Date()) }
}

enum ImageTools {
    /// At most ~1.5 megapixels, JPEG quality 0.7 (about 150–400 KB).
    static func downscaledJPEG(_ image: UIImage, maxPixels: CGFloat = 1_500_000) -> Data? {
        let w = image.size.width * image.scale, h = image.size.height * image.scale
        guard w > 0, h > 0 else { return nil }
        let factor = min(1, (maxPixels / (w * h)).squareRoot())
        let size = CGSize(width: (w * factor).rounded(), height: (h * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return scaled.jpegData(compressionQuality: 0.7)
    }
}

extension Double {
    var kcalText: String { "\(Int(self.rounded())) kcal" }
    var gramsText: String { self < 10 ? String(format: "%.1f g", self) : "\(Int(self.rounded())) g" }
}
#endif
