package com.kimhwi.dailymapline

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import com.kimhwi.dailymapline.core.Branch
import com.kimhwi.dailymapline.core.BranchState
import com.kimhwi.dailymapline.core.Coordinate
import com.kimhwi.dailymapline.core.RoadRouting
import com.kimhwi.dailymapline.core.RouteResult
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.zip.Deflater
import java.util.zip.DeflaterOutputStream
import java.util.zip.Inflater
import java.util.zip.InflaterInputStream

data class Node(val id: Long, val coordinate: Coordinate)
data class DeletionPreview(val deletedNodes: Int, val deletedBranches: Int, val retainedNodes: Int, val referencedBy: List<String>)
data class BackupSummary(val dates: List<String>, val nodeCount: Int, val branchCount: Int)
class StoreException(message: String) : Exception(message)

/**
 * Local record database, same schema and rules as iOS. Nodes have no timestamp column by design.
 * A branch belongs to the date of its end node, so the next day starts from the previous day's
 * last node by reference, without duplicating it.
 */
class RecordStore(context: Context, name: String? = "records.sqlite") :
    SQLiteOpenHelper(context, name, null, 2) {

    override fun onConfigure(db: SQLiteDatabase) {
        db.setForeignKeyConstraintsEnabled(true)
        // Deleted records should not linger in free database pages.
        db.rawQuery("PRAGMA secure_delete = ON", null).close()
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE days (id INTEGER PRIMARY KEY, date TEXT NOT NULL UNIQUE)")
        db.execSQL(
            """CREATE TABLE nodes (id INTEGER PRIMARY KEY AUTOINCREMENT, day_id INTEGER NOT NULL REFERENCES days(id),
            lon REAL NOT NULL, lat REAL NOT NULL, retained INTEGER NOT NULL DEFAULT 0)""",
        )
        db.execSQL(
            """CREATE TABLE branches (id INTEGER PRIMARY KEY AUTOINCREMENT, day_id INTEGER NOT NULL REFERENCES days(id),
            from_node INTEGER NOT NULL REFERENCES nodes(id), to_node INTEGER NOT NULL UNIQUE REFERENCES nodes(id),
            state TEXT NOT NULL, path TEXT NOT NULL)""",
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit

    /** Saves the node first in its own transaction, so a routing failure cannot lose the observed position. */
    fun record(coordinate: Coordinate, date: String, router: RoadRouting?, speedKmh: Double = 0.0, afterGap: Boolean = false): Node {
        val db = writableDatabase
        val previous = lastNode()
        val node = transaction {
            db.execSQL("INSERT OR IGNORE INTO days(date) VALUES (?)", arrayOf(date))
            val id = db.insertOrThrow("nodes", null, ContentValues().apply {
                put("day_id", dayId(date)); put("lon", coordinate.lon); put("lat", coordinate.lat)
            })
            Node(id, coordinate)
        }
        if (previous == null) return node
        val (state, path) = when {
            afterGap -> BranchState.Gap to emptyList()
            else -> when (val result = router?.route(previous.coordinate, coordinate, speedKmh) ?: RouteResult.DataMissing) {
                is RouteResult.Road -> BranchState.Road to result.path
                RouteResult.DataMissing -> BranchState.DataMissing to emptyList()
                RouteResult.Failed -> BranchState.Failed to emptyList()
            }
        }
        db.insertOrThrow("branches", null, ContentValues().apply {
            put("day_id", dayId(date)); put("from_node", previous.id); put("to_node", node.id)
            put("state", state.raw); put("path", encodePath(path))
        })
        return node
    }

    /** Retries branches that missing data or a failed calculation left unconnected. Gaps stay gaps. */
    fun recalculateUnconnected(router: RoadRouting): Int {
        val pending = query(
            """SELECT b.id, f.lon, f.lat, t.lon, t.lat FROM branches b JOIN nodes f ON f.id = b.from_node
            JOIN nodes t ON t.id = b.to_node WHERE b.state IN ('dataMissing', 'failed')""",
        ) { Triple(it.getLong(0), Coordinate(it.getDouble(1), it.getDouble(2)), Coordinate(it.getDouble(3), it.getDouble(4))) }
        var connected = 0
        for ((id, from, to) in pending) {
            val result = router.route(from, to, 0.0) as? RouteResult.Road ?: continue
            writableDatabase.execSQL("UPDATE branches SET state = 'road', path = ? WHERE id = ?", arrayOf<Any>(encodePath(result.path), id))
            connected++
        }
        return connected
    }

    fun recordedDates(): List<String> =
        query("SELECT date FROM days WHERE EXISTS (SELECT 1 FROM nodes WHERE day_id = days.id AND retained = 0) ORDER BY date") { it.getString(0) }

    fun nodes(date: String): List<Node> = query(
        "SELECT n.id, n.lon, n.lat FROM nodes n JOIN days d ON d.id = n.day_id WHERE d.date = ? AND n.retained = 0 ORDER BY n.id",
        date,
    ) { Node(it.getLong(0), Coordinate(it.getDouble(1), it.getDouble(2))) }

    fun branches(date: String) = branchesWhere("WHERE d.date = ?", date)

    /** Inclusive range of local dates, in recording order. */
    fun branches(from: String, to: String) = branchesWhere("WHERE d.date BETWEEN ? AND ?", from, to)

    fun allBranches() = branchesWhere("")

    fun lastNode(): Node? =
        query("SELECT id, lon, lat FROM nodes ORDER BY id DESC LIMIT 1") { Node(it.getLong(0), Coordinate(it.getDouble(1), it.getDouble(2))) }.firstOrNull()

    fun nodeCount(): Int = query("SELECT COUNT(*) FROM nodes") { it.getInt(0) }.first()

    fun deletionPreview(date: String): DeletionPreview {
        val scope = "n.day_id = (SELECT id FROM days WHERE date = ?) AND n.retained = 0"
        val nodeCount = query("SELECT COUNT(*) FROM nodes n WHERE $scope", date) { it.getInt(0) }.first()
        val branchCount = query("SELECT COUNT(*) FROM branches b JOIN days d ON d.id = b.day_id WHERE d.date = ?", date) { it.getInt(0) }.first()
        val retained = query(
            """SELECT DISTINCT n.id, d.date FROM nodes n
            JOIN branches b ON b.from_node = n.id AND b.day_id <> n.day_id AND b.state <> 'gap'
            JOIN days d ON d.id = b.day_id WHERE $scope ORDER BY d.date""",
            date,
        ) { it.getLong(0) to it.getString(1) }
        val retainedCount = retained.map { it.first }.toSet().size
        return DeletionPreview(nodeCount - retainedCount, branchCount, retainedCount, retained.map { it.second })
    }

    /**
     * Deletes one date. A node that a later date's connection starts from is kept, hidden from its
     * old date, and removed once nothing starts from it. Gap branches do not keep a node alive.
     */
    fun deleteDay(date: String) = transaction {
        val db = writableDatabase
        val day = dayIdOrNull(date) ?: return@transaction
        db.execSQL("DELETE FROM branches WHERE day_id = ?", arrayOf(day))
        db.execSQL("DELETE FROM branches WHERE state = 'gap' AND from_node IN (SELECT id FROM nodes WHERE day_id = ? AND retained = 0)", arrayOf(day))
        db.execSQL("UPDATE nodes SET retained = 1 WHERE day_id = ? AND retained = 0 AND id IN (SELECT from_node FROM branches)", arrayOf(day))
        db.execSQL("DELETE FROM nodes WHERE day_id = ? AND retained = 0", arrayOf(day))
        db.execSQL("DELETE FROM nodes WHERE retained = 1 AND id NOT IN (SELECT from_node FROM branches)")
        db.execSQL("DELETE FROM days WHERE id NOT IN (SELECT day_id FROM nodes) AND id NOT IN (SELECT day_id FROM branches)")
    }

    // Backup: same format as iOS (raw DEFLATE, as Apple's zlib option writes), so a backup moves between platforms.

    fun exportBackup(): ByteArray {
        val days = JSONArray(query("SELECT id, date FROM days ORDER BY id") { JSONObject().put("id", it.getLong(0)).put("date", it.getString(1)) })
        val nodes = JSONArray(query("SELECT id, day_id, lon, lat, retained FROM nodes ORDER BY id") {
            JSONObject().put("id", it.getLong(0)).put("dayID", it.getLong(1)).put("lon", it.getDouble(2)).put("lat", it.getDouble(3)).put("retained", it.getInt(4) != 0)
        })
        val branches = JSONArray(query("SELECT day_id, from_node, to_node, state, path FROM branches ORDER BY to_node") {
            JSONObject().put("dayID", it.getLong(0)).put("from", it.getLong(1)).put("to", it.getLong(2)).put("state", it.getString(3)).put("path", JSONArray(it.getString(4)))
        })
        val json = JSONObject().put("formatVersion", 1).put("days", days).put("nodes", nodes).put("branches", branches).toString().toByteArray()
        val compressed = ByteArrayOutputStream().also { out -> DeflaterOutputStream(out, Deflater(Deflater.DEFAULT_COMPRESSION, true)).use { it.write(json) } }.toByteArray()
        return MAGIC + MessageDigest.getInstance("SHA-256").digest(json) + compressed
    }

    /** Replaces all records with the backup, all or nothing. */
    fun restoreBackup(data: ByteArray) {
        val payload = decodeBackup(data)
        transaction {
            val db = writableDatabase
            db.execSQL("DELETE FROM branches"); db.execSQL("DELETE FROM nodes"); db.execSQL("DELETE FROM days")
            payload.days.forEach { db.execSQL("INSERT INTO days(id, date) VALUES (?, ?)", arrayOf<Any>(it.getLong("id"), it.getString("date"))) }
            payload.nodes.forEach {
                db.execSQL("INSERT INTO nodes(id, day_id, lon, lat, retained) VALUES (?, ?, ?, ?, ?)",
                    arrayOf<Any>(it.getLong("id"), it.getLong("dayID"), it.getDouble("lon"), it.getDouble("lat"), if (it.getBoolean("retained")) 1 else 0))
            }
            payload.branches.forEach {
                db.execSQL("INSERT INTO branches(day_id, from_node, to_node, state, path) VALUES (?, ?, ?, ?, ?)",
                    arrayOf<Any>(it.getLong("dayID"), it.getLong("from"), it.getLong("to"), it.getString("state"), it.getJSONArray("path").toString()))
            }
        }
    }

    private fun branchesWhere(clause: String, vararg args: String): List<Branch> = query(
        "SELECT b.from_node, b.to_node, b.state, b.path FROM branches b JOIN days d ON d.id = b.day_id $clause ORDER BY b.to_node", *args,
    ) { Branch(it.getLong(0), it.getLong(1), BranchState.of(it.getString(2)), decodePath(it.getString(3))) }

    private fun dayIdOrNull(date: String): Long? = query("SELECT id FROM days WHERE date = ?", date) { it.getLong(0) }.firstOrNull()
    private fun dayId(date: String) = dayIdOrNull(date) ?: throw StoreException("day missing")

    private fun <T> query(sql: String, vararg args: String, map: (Cursor) -> T): List<T> =
        readableDatabase.rawQuery(sql, args).use { cursor -> buildList { while (cursor.moveToNext()) add(map(cursor)) } }

    private fun <T> transaction(body: () -> T): T {
        val db = writableDatabase
        db.beginTransaction()
        try {
            return body().also { db.setTransactionSuccessful() }
        } finally {
            db.endTransaction()
        }
    }

    companion object {
        private val MAGIC = "DMLBACKUP1\n".toByteArray()

        private class Payload(val days: List<JSONObject>, val nodes: List<JSONObject>, val branches: List<JSONObject>)

        fun inspectBackup(data: ByteArray): BackupSummary {
            val payload = decodeBackup(data)
            val recorded = payload.nodes.filter { !it.getBoolean("retained") }.map { it.getLong("dayID") }.toSet()
            return BackupSummary(
                payload.days.filter { it.getLong("id") in recorded }.map { it.getString("date") }.sorted(),
                payload.nodes.size, payload.branches.size,
            )
        }

        /** Rejects anything that could not restore into a consistent database. */
        private fun decodeBackup(data: ByteArray): Payload {
            if (data.size <= MAGIC.size + 32 || !data.copyOfRange(0, MAGIC.size).contentEquals(MAGIC)) {
                throw StoreException("DailyMapLine 백업 파일이 아니에요.")
            }
            val digest = data.copyOfRange(MAGIC.size, MAGIC.size + 32)
            val json = runCatching { InflaterInputStream(data.inputStream(MAGIC.size + 32, data.size - MAGIC.size - 32), Inflater(true)).readBytes() }.getOrNull()
            if (json == null || !MessageDigest.getInstance("SHA-256").digest(json).contentEquals(digest)) {
                throw StoreException("백업 파일이 손상되었어요.")
            }
            val root = runCatching { JSONObject(String(json)) }.getOrNull() ?: throw StoreException("백업 파일이 손상되었어요.")
            if (root.optInt("formatVersion") != 1) throw StoreException("지원하지 않는 백업 버전이에요.")
            fun list(key: String) = root.getJSONArray(key).let { a -> (0 until a.length()).map { a.getJSONObject(it) } }
            val payload = runCatching { Payload(list("days"), list("nodes"), list("branches")) }.getOrNull()
                ?: throw StoreException("백업 파일의 내용이 올바르지 않아요.")
            val dayIds = payload.days.map { it.getLong("id") }.toSet()
            val nodeIds = payload.nodes.map { it.getLong("id") }.toSet()
            val states = BranchState.entries.map { it.raw }.toSet()
            val valid = dayIds.size == payload.days.size &&
                payload.days.map { it.getString("date") }.toSet().size == payload.days.size &&
                nodeIds.size == payload.nodes.size &&
                payload.nodes.all { it.getLong("dayID") in dayIds } &&
                payload.branches.all { it.getLong("dayID") in dayIds && it.getLong("from") in nodeIds && it.getLong("to") in nodeIds && it.getString("state") in states } &&
                payload.branches.map { it.getLong("to") }.toSet().size == payload.branches.size
            if (!valid) throw StoreException("백업 파일의 내용이 올바르지 않아요.")
            return payload
        }

        fun encodePath(path: List<Coordinate>) =
            JSONArray(path.map { JSONObject().put("lon", it.lon).put("lat", it.lat) }).toString()

        fun decodePath(text: String) = JSONArray(text).let { a ->
            (0 until a.length()).map { a.getJSONObject(it).let { o -> Coordinate(o.getDouble("lon"), o.getDouble("lat")) } }
        }
    }
}
