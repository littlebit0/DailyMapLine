package com.kimhwi.dailymapline

import android.app.Application
import android.content.Context
import com.kimhwi.dailymapline.core.Branch
import com.kimhwi.dailymapline.core.Coordinate
import com.kimhwi.dailymapline.core.RecordingPolicy
import com.kimhwi.dailymapline.core.distanceMeters
import com.valhalla.valhalla.Valhalla
import com.valhalla.valhalla.config.ValhallaConfigFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

enum class RecordingStatus(val text: String) {
    Off("위치 기록이 꺼져 있어요."),
    WaitingPermission("위치 권한을 허용하면 기록을 시작해요."),
    Denied("위치 권한을 확인해 주세요. 기존 기록은 볼 수 있어요."),
    Moving("이동을 기록하고 있어요."),
    Stopped("머무는 동안 노드 기록을 쉬고 있어요."),
    NoSignal("현재 위치를 받지 못하고 있어요."),
    NoRoad("길이 없는 곳이라 기록하지 않고 있어요."),
}

/** App-wide state shared by the screens and the recording service. */
class DailyMapLineApp : Application() {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    lateinit var store: RecordStore
    @Volatile var router: ValhallaRouter? = null
    val branches = MutableStateFlow<List<Branch>>(emptyList())
    /** Road path from the last node to the current position, shown until the next node is saved. Never stored. */
    val livePath = MutableStateFlow<List<Coordinate>>(emptyList())
    val dates = MutableStateFlow<Set<String>>(emptySet())
    val status = MutableStateFlow(RecordingStatus.Off)
    val dataReady = MutableStateFlow(false)
    val errorMessage = MutableStateFlow<String?>(null)
    val currentLocation = MutableStateFlow<android.location.Location?>(null)

    private val prefs by lazy { getSharedPreferences("settings", Context.MODE_PRIVATE) }
    var recordingEnabled: Boolean
        get() = prefs.getBoolean("recordingEnabled", false)
        set(value) = prefs.edit().putBoolean("recordingEnabled", value).apply()
    var pendingGap: Boolean
        get() = prefs.getBoolean("pendingGap", false)
        set(value) = prefs.edit().putBoolean("pendingGap", value).apply()
    var didShowIntro: Boolean
        get() = prefs.getBoolean("didShowIntro", false)
        set(value) = prefs.edit().putBoolean("didShowIntro", value).apply()

    private val policy = RecordingPolicy()
    private var lastFix: android.location.Location? = null

    override fun onCreate() {
        super.onCreate()
        store = RecordStore(this)
        reload()
        scope.launch {
            // shortcut: copies about 1 GB of assets on first launch because the map and router need file paths; ship as downloadable data before release.
            copyAsset("korea.pmtiles")
            val tiles = copyAsset("valhalla_tiles.tar")
            router = runCatching {
                ValhallaRouter(Valhalla(this@DailyMapLineApp, ValhallaConfigFactory.usingTileExtract(tiles.absolutePath)))
            }.getOrNull()
            router?.let { runCatching { store.recalculateUnconnected(it) } }
            reload()
            dataReady.value = true
        }
    }

    fun dataFile(name: String) = File(filesDir, name)

    private fun copyAsset(name: String): File {
        val target = dataFile(name)
        val size = runCatching { assets.openFd(name).use { it.length } }.getOrDefault(-1)
        if (target.length() == size) return target
        val temporary = File(filesDir, "$name.partial")
        assets.open(name).use { input -> temporary.outputStream().use { input.copyTo(it, 1 shl 20) } }
        temporary.renameTo(target)
        return target
    }

    fun reload() {
        runCatching {
            branches.value = store.allBranches()
            dates.value = store.recordedDates().toSet()
        }.onFailure { errorMessage.value = "기록을 읽지 못했어요. ${it.message}" }
    }

    /** Called for every location fix while recording is on. */
    @Synchronized
    fun handle(location: android.location.Location) {
        currentLocation.value = location
        if (!recordingEnabled || !location.hasAccuracy() || location.accuracy > 100) return
        val previous = lastFix
        var speed = if (location.hasSpeed()) location.speed * 3.6 else 0.0
        if (!location.hasSpeed() && previous != null && location.time > previous.time) {
            speed = location.distanceTo(previous) / ((location.time - previous.time) / 1000.0) * 3.6
        }
        if (previous != null && location.time - previous.time >= GAP_MILLIS) pendingGap = true
        lastFix = location
        val fix = Coordinate(location.longitude, location.latitude)
        if (router?.hasNoRoad(fix) == true) {
            // Off-road positions are not stored, so the next node must not connect across them.
            pendingGap = true
            status.value = RecordingStatus.NoRoad
            return
        }
        val record = policy.shouldRecord(fix, speed, location.time)
        status.value = if (policy.isStopped) RecordingStatus.Stopped else RecordingStatus.Moving
        updateLivePath(fix, speed)
        if (!record) return
        runCatching {
            store.record(fix, localDate(Date(location.time)), router, speed, pendingGap)
            pendingGap = false
            livePath.value = emptyList()
            reload()
        }.onFailure { errorMessage.value = "위치를 저장하지 못했어요. ${it.message}" }
    }

    /** Follows the same road-only rule as branches, and never bridges a gap the next node will not connect. */
    private fun updateLivePath(fix: Coordinate, speedKmh: Double) {
        val last = store.lastNode()
        val router = router
        if (pendingGap || last == null || router == null) { livePath.value = emptyList(); return }
        // Routing every fix is wasted work when the position barely moved.
        livePath.value.lastOrNull()?.let { if (distanceMeters(it, fix) < 10) return }
        (router.route(last.coordinate, fix, speedKmh) as? com.kimhwi.dailymapline.core.RouteResult.Road)?.let { livePath.value = it.path }
    }

    fun deleteDay(date: String): Boolean = runCatching {
        // Without its last node the next fix must not be routed from an older position.
        if (store.lastNode()?.let { last -> store.nodes(date).contains(last) } == true) pendingGap = true
        store.deleteDay(date)
        // Any generated video may cover this date, so none of them outlive the deletion.
        File(cacheDir, "videos").deleteRecursively()
        reload()
    }.onFailure { errorMessage.value = "기록을 삭제하지 못했어요. 기존 기록은 그대로예요. ${it.message}" }.isSuccess

    fun restoreBackup(data: ByteArray): Boolean = runCatching {
        // The restored last node is unrelated to the next position.
        pendingGap = true
        store.restoreBackup(data)
        reload()
    }.onFailure { errorMessage.value = "백업을 복원하지 못했어요. 기존 기록은 그대로예요. ${it.message}" }.isSuccess

    companion object {
        /** Experimental: a silence this long is treated as a reception gap and is not routed across. */
        private const val GAP_MILLIS = 600_000L

        fun localDate(date: Date): String = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(date)
    }
}
