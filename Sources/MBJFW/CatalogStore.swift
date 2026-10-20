import CSQLite
import Foundation

@MainActor
final class CatalogStore {
    static let shared = CatalogStore()

    private var database: OpaquePointer?
    private(set) var failure: String?

    private init() {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "MBJFW")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let path = support.appending(path: "catalog.sqlite3").path
            guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                throw CatalogStoreError.open(database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open catalog")
            }
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;")
            try execute("CREATE TABLE IF NOT EXISTS catalog_state (key TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, updated_at REAL NOT NULL);")
        } catch { failure = error.localizedDescription }
    }

    func load(_ key: String, defaults: UserDefaults = .standard) -> Data? {
        do {
            if let stored = try read(key) { return stored }
            guard let legacy = defaults.data(forKey: key) else { return nil }
            try write(legacy, key: key)
            defaults.removeObject(forKey: key)
            return legacy
        } catch {
            failure = error.localizedDescription
            return defaults.data(forKey: key)
        }
    }

    func save(_ data: Data, key: String, defaults: UserDefaults = .standard) throws {
        try write(data, key: key)
        defaults.removeObject(forKey: key)
        failure = nil
    }

    private func read(_ key: String) throws -> Data? {
        guard let database else { throw CatalogStoreError.unavailable(failure ?? "Catalog is unavailable") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT payload FROM catalog_state WHERE key = ?1", -1, &statement, nil) == SQLITE_OK else {
            throw CatalogStoreError.query(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, index: 1)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw CatalogStoreError.query(String(cString: sqlite3_errmsg(database))) }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func write(_ data: Data, key: String) throws {
        guard let database else { throw CatalogStoreError.unavailable(failure ?? "Catalog is unavailable") }
        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT INTO catalog_state(key,payload,updated_at) VALUES(?1,?2,?3) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload,updated_at=excluded.updated_at", -1, &statement, nil) == SQLITE_OK else {
                throw CatalogStoreError.query(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            bind(key, to: statement, index: 1)
            data.withUnsafeBytes { bytes in
                _ = sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), transient)
            }
            _ = sqlite3_bind_double(statement, 3, Date.now.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CatalogStoreError.query(String(cString: sqlite3_errmsg(database))) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw CatalogStoreError.unavailable(failure ?? "Catalog is unavailable") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw CatalogStoreError.query(message)
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer?, index: Int32) {
        value.withCString { _ = sqlite3_bind_text(statement, index, $0, -1, transient) }
    }

    private var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
}

private enum CatalogStoreError: LocalizedError {
    case open(String)
    case query(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .open(message): "The local catalog could not be opened: \(message)"
        case let .query(message): "The local catalog could not be updated: \(message)"
        case let .unavailable(message): message
        }
    }
}
