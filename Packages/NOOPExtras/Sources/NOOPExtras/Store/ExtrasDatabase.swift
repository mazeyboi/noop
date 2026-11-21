import Foundation
import GRDB

/// The extras module's own SQLite file. NOOP's database (`whoop.sqlite`) is never written to.
public enum ExtrasDatabase {
    /// `Application Support/NOOPExtras/extras.sqlite`
    public static func defaultURL() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("NOOPExtras", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        #if os(iOS)
        // Readable after first unlock, like NOOP's own store, so a background sync can open it.
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                              ofItemAtPath: base.path)
        #endif
        return base.appendingPathComponent("extras.sqlite")
    }

    public static func open(at url: URL) throws -> DatabaseQueue {
        let q = try DatabaseQueue(path: url.path)
        try migrator.migrate(q)
        return q
    }

    public static func inMemory() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try migrator.migrate(q)
        return q
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            // Each owned record is stored whole as JSON, plus the few columns queries need.
            for table in ["food", "entry", "savedMeal", "targets"] {
                try db.create(table: table) { t in
                    t.column("id", .text).primaryKey()
                    t.column("json", .text).notNull()
                    t.column("updatedAt", .double).notNull()
                    t.column("deleted", .boolean).notNull().defaults(to: false)
                    t.column("dirty", .boolean).notNull().defaults(to: true)
                }
            }
            try db.alter(table: "food") { t in
                t.add(column: "barcode", .text)
                t.add(column: "favourite", .boolean).notNull().defaults(to: false)
                t.add(column: "lastUsedAt", .double)
            }
            try db.alter(table: "entry") { t in
                t.add(column: "at", .double).notNull().defaults(to: 0)
                t.add(column: "status", .text).notNull().defaults(to: "logged")
            }
            try db.create(index: "idx_entry_at", on: "entry", columns: ["at"])
            try db.create(index: "idx_food_barcode", on: "food", columns: ["barcode"])
            try db.create(table: "photo") { t in
                t.column("id", .text).primaryKey()
                t.column("fileName", .text).notNull()
                t.column("uploaded", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .double).notNull()
            }
            try db.create(table: "offCache") { t in
                t.column("barcode", .text).primaryKey()
                t.column("json", .text)          // nil = not found
                t.column("fetchedAt", .double).notNull()
            }
            try db.create(table: "quarantine") { t in
                t.column("kind", .text).notNull()
                t.column("id", .text).notNull()
                t.column("error", .text).notNull()
                t.column("payload", .text).notNull()
                t.column("at", .double).notNull()
                t.primaryKey(["kind", "id"])
            }
            try db.create(table: "syncLedger") { t in
                t.column("kind", .text).notNull()
                t.column("id", .text).notNull()
                t.column("hash", .text).notNull()
                t.primaryKey(["kind", "id"])
            }
            try db.create(table: "kv") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        return m
    }
}
