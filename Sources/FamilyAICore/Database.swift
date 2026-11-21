import Foundation
import SQLite3

/// A value that can be bound to / read from SQLite.
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public var string: String? { if case .text(let s) = self { return s }; return nil }
    public var int: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        default: return nil
        }
    }
    public var double: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    public var data: Data? { if case .blob(let d) = self { return d }; return nil }
    public var bool: Bool { (int ?? 0) != 0 }
}

public typealias Row = [String: SQLValue]

public enum DatabaseError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String, String)
    case step(String, String)

    public var description: String {
        switch self {
        case .open(let m): return "SQLite open: \(m)"
        case .prepare(let sql, let m): return "SQLite prepare (\(sql.prefix(80))): \(m)"
        case .step(let sql, let m): return "SQLite step (\(sql.prefix(80))): \(m)"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal thread-safe SQLite wrapper. All access is serialised through the actor.
public actor Database {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            throw DatabaseError.open(String(cString: sqlite3_errmsg(db)))
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        _ = try Database.execRaw(db, "PRAGMA journal_mode=WAL")
        _ = try Database.execRaw(db, "PRAGMA foreign_keys=ON")
    }

    deinit { if let handle { sqlite3_close(handle) } }

    @discardableResult
    public func execute(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        guard let handle else { throw DatabaseError.open("closed") }
        _ = try Database.run(handle, sql, params)
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [Row] {
        guard let handle else { throw DatabaseError.open("closed") }
        return try Database.run(handle, sql, params)
    }

    public func queryOne(_ sql: String, _ params: [SQLValue] = []) throws -> Row? {
        try query(sql, params).first
    }

    /// Runs several statements atomically.
    public func transaction(_ statements: [(String, [SQLValue])]) throws {
        guard let handle else { throw DatabaseError.open("closed") }
        _ = try Database.execRaw(handle, "BEGIN IMMEDIATE")
        do {
            for (sql, params) in statements { _ = try Database.run(handle, sql, params) }
            _ = try Database.execRaw(handle, "COMMIT")
        } catch {
            _ = try? Database.execRaw(handle, "ROLLBACK")
            throw error
        }
    }

    public func executeScript(_ sql: String) throws {
        guard let handle else { throw DatabaseError.open("closed") }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError.step(sql, msg)
        }
    }

    private static func execRaw(_ db: OpaquePointer, _ sql: String) throws -> [Row] {
        try run(db, sql, [])
    }

    private static func run(_ db: OpaquePointer, _ sql: String, _ params: [SQLValue]) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.prepare(sql, String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                _ = v.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
                }
            }
        }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw DatabaseError.step(sql, String(cString: sqlite3_errmsg(db)))
            }
            var row: Row = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if let p = sqlite3_column_blob(stmt, c), n > 0 {
                        row[name] = .blob(Data(bytes: p, count: n))
                    } else {
                        row[name] = .blob(Data())
                    }
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }
}

extension SQLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int) { self = .int(Int64(value)) }
    public static func of(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
    public static func of(_ b: Bool) -> SQLValue { .int(b ? 1 : 0) }
}
