import CryptoKit
import Foundation
import SQLite3

public struct Node: Equatable, Sendable {
    public let id: Int64
    public let coordinate: Coordinate
}

public enum BranchState: String, Sendable {
    case road
    case dataMissing
    case failed
    /// Recording or reception break. Never drawn as a connection.
    case gap
}

public struct Branch: Equatable, Sendable {
    public let from: Int64
    public let to: Int64
    public let state: BranchState
    public let path: [Coordinate]
}

public struct DeletionPreview: Equatable, Sendable {
    public let deletedNodes: Int
    public let deletedBranches: Int
    public let retainedNodes: Int
    /// Later dates whose connection starts from a retained node.
    public let referencedBy: [String]
}

public struct BackupSummary: Equatable, Sendable {
    public let dates: [String]
    public let nodeCount: Int
    public let branchCount: Int
}

/// Compressed, unencrypted single-file backup: magic, SHA-256 of the JSON, then zlib-compressed JSON.
private struct BackupPayload: Codable {
    struct Day: Codable { let id: Int64; let date: String }
    struct StoredNode: Codable { let id: Int64; let dayID: Int64; let lon: Double; let lat: Double; let retained: Bool }
    struct StoredBranch: Codable { let dayID: Int64; let from: Int64; let to: Int64; let state: String; let path: [Coordinate] }

    static let magic = Data("DMLBACKUP1\n".utf8)
    let formatVersion: Int
    let days: [Day]
    let nodes: [StoredNode]
    let branches: [StoredBranch]

    func encoded() throws -> Data {
        let json = try JSONEncoder().encode(self)
        return Self.magic + Data(SHA256.hash(data: json)) + (try (json as NSData).compressed(using: .zlib) as Data)
    }

    /// Rejects anything that could not restore into a consistent database.
    static func decode(_ data: Data) throws -> BackupPayload {
        let digestLength = SHA256.byteCount
        guard data.count > magic.count + digestLength, data.prefix(magic.count) == magic else {
            throw StoreError(description: "DailyMapLine 백업 파일이 아니에요.")
        }
        let digest = data.dropFirst(magic.count).prefix(digestLength)
        let body = Data(data.dropFirst(magic.count + digestLength))
        guard let json = try? (body as NSData).decompressed(using: .zlib) as Data,
              Data(SHA256.hash(data: json)) == digest,
              let payload = try? JSONDecoder().decode(BackupPayload.self, from: json) else {
            throw StoreError(description: "백업 파일이 손상되었어요.")
        }
        guard payload.formatVersion == 1 else {
            throw StoreError(description: "지원하지 않는 백업 버전이에요.")
        }
        let dayIDs = Set(payload.days.map(\.id))
        let nodeIDs = Set(payload.nodes.map(\.id))
        let valid = dayIDs.count == payload.days.count
            && Set(payload.days.map(\.date)).count == payload.days.count
            && nodeIDs.count == payload.nodes.count
            && payload.nodes.allSatisfy { dayIDs.contains($0.dayID) }
            && payload.branches.allSatisfy {
                dayIDs.contains($0.dayID) && nodeIDs.contains($0.from) && nodeIDs.contains($0.to) && BranchState(rawValue: $0.state) != nil
            }
            && Set(payload.branches.map(\.to)).count == payload.branches.count
        guard valid else { throw StoreError(description: "백업 파일의 내용이 올바르지 않아요.") }
        return payload
    }

    var summary: BackupSummary {
        let recorded = Set(nodes.filter { !$0.retained }.map(\.dayID))
        return BackupSummary(
            dates: days.filter { recorded.contains($0.id) }.map(\.date).sorted(),
            nodeCount: nodes.count,
            branchCount: branches.count
        )
    }
}

public struct StoreError: Error, CustomStringConvertible {
    public let description: String
}

/// Local record database. Nodes have no timestamp column by design: only order and local date.
/// A branch belongs to the date of its end node, so the next day starts from the previous day's
/// last node by reference, without duplicating it.
public final class RecordStore {
    private var db: OpaquePointer?

    public init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw StoreError(description: "sqlite open failed: \(path)")
        }
        try execute("PRAGMA foreign_keys = ON")
        try execute("""
        CREATE TABLE IF NOT EXISTS days (id INTEGER PRIMARY KEY, date TEXT NOT NULL UNIQUE);
        CREATE TABLE IF NOT EXISTS nodes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            day_id INTEGER NOT NULL REFERENCES days(id),
            lon REAL NOT NULL,
            lat REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS branches (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            day_id INTEGER NOT NULL REFERENCES days(id),
            from_node INTEGER NOT NULL REFERENCES nodes(id),
            to_node INTEGER NOT NULL UNIQUE REFERENCES nodes(id),
            state TEXT NOT NULL,
            path TEXT NOT NULL
        );
        """)
        // Deleted records should not linger in free database pages.
        try execute("PRAGMA secure_delete = ON")
        let version = try query("PRAGMA user_version") { sqlite3_column_int($0, 0) }.first ?? 0
        if version < 2 {
            try transaction {
                try execute("ALTER TABLE nodes ADD COLUMN retained INTEGER NOT NULL DEFAULT 0")
                try execute("PRAGMA user_version = 2")
            }
        }
    }

    deinit { sqlite3_close(db) }

    /// Saves the node first in its own transaction, so a routing failure cannot lose the observed position.
    @discardableResult
    public func record(_ coordinate: Coordinate, date: String, router: (any RoadRouting)?, speedKmh: Double = 0, afterGap: Bool = false) throws -> Node {
        let previous = try lastNode()
        let node = try transaction { () -> Node in
            try run("INSERT OR IGNORE INTO days(date) VALUES (?)", [.text(date)])
            let dayID = try dayID(date)!
            try run("INSERT INTO nodes(day_id, lon, lat) VALUES (?, ?, ?)", [.int(dayID), .real(coordinate.lon), .real(coordinate.lat)])
            return Node(id: sqlite3_last_insert_rowid(db), coordinate: coordinate)
        }
        guard let previous else { return node }
        let state: BranchState
        var path: [Coordinate] = []
        if afterGap {
            state = .gap
        } else {
            switch router?.route(from: previous.coordinate, to: coordinate, speedKmh: speedKmh) ?? .dataMissing {
            case .road(let road): (state, path) = (.road, road)
            case .dataMissing: state = .dataMissing
            case .failed: state = .failed
            }
        }
        let encoded = String(decoding: try JSONEncoder().encode(path), as: UTF8.self)
        try run(
            "INSERT INTO branches(day_id, from_node, to_node, state, path) VALUES (?, ?, ?, ?, ?)",
            [.int(try dayID(date)!), .int(previous.id), .int(node.id), .text(state.rawValue), .text(encoded)]
        )
        return node
    }

    /// Retries branches that missing data or a failed calculation left unconnected. Gaps stay gaps.
    @discardableResult
    public func recalculateUnconnected(router: any RoadRouting) throws -> Int {
        let pending = try query("""
            SELECT b.id, f.lon, f.lat, t.lon, t.lat FROM branches b
            JOIN nodes f ON f.id = b.from_node JOIN nodes t ON t.id = b.to_node
            WHERE b.state IN ('dataMissing', 'failed')
            """) {
            (id: sqlite3_column_int64($0, 0),
             from: Coordinate(lon: sqlite3_column_double($0, 1), lat: sqlite3_column_double($0, 2)),
             to: Coordinate(lon: sqlite3_column_double($0, 3), lat: sqlite3_column_double($0, 4)))
        }
        var connected = 0
        for branch in pending {
            guard case .road(let path) = router.route(from: branch.from, to: branch.to, speedKmh: 0) else { continue }
            let encoded = String(decoding: try JSONEncoder().encode(path), as: UTF8.self)
            try run("UPDATE branches SET state = 'road', path = ? WHERE id = ?", [.text(encoded), .int(branch.id)])
            connected += 1
        }
        return connected
    }

    public func recordedDates() throws -> [String] {
        try query("SELECT date FROM days WHERE EXISTS (SELECT 1 FROM nodes WHERE day_id = days.id AND retained = 0) ORDER BY date") { text($0, 0) }
    }

    public func deletionPreview(date: String) throws -> DeletionPreview {
        let scope = "n.day_id = (SELECT id FROM days WHERE date = ?) AND n.retained = 0"
        let nodeCount = try query("SELECT COUNT(*) FROM nodes n WHERE \(scope)", [.text(date)]) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
        let branchCount = try query("SELECT COUNT(*) FROM branches b JOIN days d ON d.id = b.day_id WHERE d.date = ?", [.text(date)]) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
        let retained = try query("""
            SELECT DISTINCT n.id, d.date FROM nodes n
            JOIN branches b ON b.from_node = n.id AND b.day_id <> n.day_id AND b.state <> 'gap'
            JOIN days d ON d.id = b.day_id
            WHERE \(scope) ORDER BY d.date
            """, [.text(date)]) { (id: sqlite3_column_int64($0, 0), date: text($0, 1)) }
        let retainedCount = Set(retained.map(\.id)).count
        return DeletionPreview(
            deletedNodes: nodeCount - retainedCount,
            deletedBranches: branchCount,
            retainedNodes: retainedCount,
            referencedBy: retained.map(\.date)
        )
    }

    /// Deletes one date. A node that a later date's connection starts from is kept, hidden from its
    /// old date, and removed once nothing starts from it. Gap branches are not connections, so they
    /// do not keep a node alive. All or nothing.
    public func deleteDay(date: String) throws {
        try transaction {
            guard let day = try dayID(date) else { return }
            try run("DELETE FROM branches WHERE day_id = ?", [.int(day)])
            try run("DELETE FROM branches WHERE state = 'gap' AND from_node IN (SELECT id FROM nodes WHERE day_id = ? AND retained = 0)", [.int(day)])
            try run("UPDATE nodes SET retained = 1 WHERE day_id = ? AND retained = 0 AND id IN (SELECT from_node FROM branches)", [.int(day)])
            try run("DELETE FROM nodes WHERE day_id = ? AND retained = 0", [.int(day)])
            try run("DELETE FROM nodes WHERE retained = 1 AND id NOT IN (SELECT from_node FROM branches)", [])
            try run("DELETE FROM days WHERE id NOT IN (SELECT day_id FROM nodes) AND id NOT IN (SELECT day_id FROM branches)", [])
        }
    }

    public func nodes(date: String) throws -> [Node] {
        try query("SELECT n.id, n.lon, n.lat FROM nodes n JOIN days d ON d.id = n.day_id WHERE d.date = ? AND n.retained = 0 ORDER BY n.id", [.text(date)]) {
            Node(id: sqlite3_column_int64($0, 0), coordinate: Coordinate(lon: sqlite3_column_double($0, 1), lat: sqlite3_column_double($0, 2)))
        }
    }

    public func branches(date: String) throws -> [Branch] {
        try branches(where: "WHERE d.date = ?", [.text(date)])
    }

    /// Inclusive range of local dates, in recording order.
    public func branches(from start: String, to end: String) throws -> [Branch] {
        try branches(where: "WHERE d.date BETWEEN ? AND ?", [.text(start), .text(end)])
    }

    public func allBranches() throws -> [Branch] {
        try branches(where: "", [])
    }

    public func lastNode() throws -> Node? {
        try query("SELECT id, lon, lat FROM nodes ORDER BY id DESC LIMIT 1") {
            Node(id: sqlite3_column_int64($0, 0), coordinate: Coordinate(lon: sqlite3_column_double($0, 1), lat: sqlite3_column_double($0, 2)))
        }.first
    }

    private func branches(where clause: String, _ values: [Value]) throws -> [Branch] {
        let sql = "SELECT b.from_node, b.to_node, b.state, b.path FROM branches b JOIN days d ON d.id = b.day_id \(clause) ORDER BY b.to_node"
        return try query(sql, values) { row in
            let path = try JSONDecoder().decode([Coordinate].self, from: Data(text(row, 3).utf8))
            guard let state = BranchState(rawValue: text(row, 2)) else {
                throw StoreError(description: "unknown branch state")
            }
            return Branch(from: sqlite3_column_int64(row, 0), to: sqlite3_column_int64(row, 1), state: state, path: path)
        }
    }

    private func dayID(_ date: String) throws -> Int64? {
        try query("SELECT id FROM days WHERE date = ?", [.text(date)]) { sqlite3_column_int64($0, 0) }.first
    }

    // MARK: Backup

    public func exportBackup() throws -> Data {
        let days = try query("SELECT id, date FROM days ORDER BY id") {
            BackupPayload.Day(id: sqlite3_column_int64($0, 0), date: text($0, 1))
        }
        let nodes = try query("SELECT id, day_id, lon, lat, retained FROM nodes ORDER BY id") {
            BackupPayload.StoredNode(
                id: sqlite3_column_int64($0, 0), dayID: sqlite3_column_int64($0, 1),
                lon: sqlite3_column_double($0, 2), lat: sqlite3_column_double($0, 3), retained: sqlite3_column_int($0, 4) != 0
            )
        }
        let branches = try query("SELECT day_id, from_node, to_node, state, path FROM branches ORDER BY to_node") { row in
            BackupPayload.StoredBranch(
                dayID: sqlite3_column_int64(row, 0), from: sqlite3_column_int64(row, 1), to: sqlite3_column_int64(row, 2),
                state: text(row, 3), path: try JSONDecoder().decode([Coordinate].self, from: Data(text(row, 4).utf8))
            )
        }
        return try BackupPayload(formatVersion: 1, days: days, nodes: nodes, branches: branches).encoded()
    }

    /// Validates a backup without touching existing records.
    public static func inspectBackup(_ data: Data) throws -> BackupSummary {
        try BackupPayload.decode(data).summary
    }

    /// Replaces all records with the backup, all or nothing.
    public func restoreBackup(_ data: Data) throws {
        let payload = try BackupPayload.decode(data)
        try transaction {
            try execute("DELETE FROM branches; DELETE FROM nodes; DELETE FROM days;")
            for day in payload.days {
                try run("INSERT INTO days(id, date) VALUES (?, ?)", [.int(day.id), .text(day.date)])
            }
            for node in payload.nodes {
                try run("INSERT INTO nodes(id, day_id, lon, lat, retained) VALUES (?, ?, ?, ?, ?)", [.int(node.id), .int(node.dayID), .real(node.lon), .real(node.lat), .int(node.retained ? 1 : 0)])
            }
            for branch in payload.branches {
                let path = String(decoding: try JSONEncoder().encode(branch.path), as: UTF8.self)
                try run("INSERT INTO branches(day_id, from_node, to_node, state, path) VALUES (?, ?, ?, ?, ?)", [.int(branch.dayID), .int(branch.from), .int(branch.to), .text(branch.state), .text(path)])
            }
        }
    }

    public func nodeCount() throws -> Int {
        try query("SELECT COUNT(*) FROM nodes") { Int(sqlite3_column_int($0, 0)) }.first ?? 0
    }

    // MARK: SQLite

    private enum Value {
        case int(Int64), real(Double), text(String)
    }

    private func text(_ row: OpaquePointer, _ column: Int32) -> String {
        String(cString: sqlite3_column_text(row, column))
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        _ = try query(sql, values) { _ in () }
    }

    private func query<T>(_ sql: String, _ values: [Value] = [], _ map: (OpaquePointer) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, position, v)
            case .real(let v): sqlite3_bind_double(statement, position, v)
            case .text(let v): sqlite3_bind_text(statement, position, v, -1, transient)
            }
        }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(try map(statement))
            case SQLITE_DONE: return rows
            default: throw lastError()
            }
        }
    }

    private func lastError() -> StoreError {
        StoreError(description: String(cString: sqlite3_errmsg(db)))
    }
}
