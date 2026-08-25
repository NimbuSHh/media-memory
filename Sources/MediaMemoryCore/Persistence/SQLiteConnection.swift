import CSQLite
import Foundation

struct SQLiteFailure: Error, LocalizedError, Sendable {
    let operation: String
    let message: String

    var errorDescription: String? {
        "SQLite \(operation) 失败：\(message)"
    }
}

enum SQLiteValue {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null
}

final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(url: URL, readOnly: Bool = false) throws {
        var database: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE)
            | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(url.path, &database, flags, nil)
        guard code == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "无法创建数据库句柄"
            if let database {
                sqlite3_close(database)
            }
            throw SQLiteFailure(operation: "open", message: message)
        }

        handle = database
        sqlite3_busy_timeout(database, 5_000)
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    func execute(_ sql: String) throws {
        guard let handle else {
            throw SQLiteFailure(operation: "execute", message: "数据库已经关闭")
        }

        var errorPointer: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard code == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorPointer)
            throw SQLiteFailure(operation: "execute", message: message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else {
            throw SQLiteFailure(operation: "prepare", message: "数据库已经关闭")
        }

        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw SQLiteFailure(
                operation: "prepare",
                message: String(cString: sqlite3_errmsg(handle))
            )
        }

        return SQLiteStatement(database: handle, statement: statement)
    }

    func inTransaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func inReadTransaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

final class SQLiteStatement {
    private let database: OpaquePointer
    private let statement: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(database: OpaquePointer, statement: OpaquePointer) {
        self.database = database
        self.statement = statement
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func bind(_ value: SQLiteValue, at index: Int32) throws {
        let code: Int32
        switch value {
        case let .integer(number):
            code = sqlite3_bind_int64(statement, index, number)
        case let .real(number):
            code = sqlite3_bind_double(statement, index, number)
        case let .text(text):
            code = text.withCString {
                sqlite3_bind_text(statement, index, $0, -1, transient)
            }
        case let .blob(data):
            code = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
            }
        case .null:
            code = sqlite3_bind_null(statement, index)
        }

        guard code == SQLITE_OK else {
            throw failure(operation: "bind")
        }
    }

    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            true
        case SQLITE_DONE:
            false
        default:
            throw failure(operation: "step")
        }
    }

    func integer(at index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func real(at index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func text(at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    func blob(at index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: count)
    }

    private func failure(operation: String) -> SQLiteFailure {
        SQLiteFailure(operation: operation, message: String(cString: sqlite3_errmsg(database)))
    }
}
