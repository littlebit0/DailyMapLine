package com.kimhwi.dailymapline

import android.Manifest
import android.annotation.SuppressLint
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationListener
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import com.kimhwi.dailymapline.core.Branch
import com.kimhwi.dailymapline.core.VideoTimeline
import kotlinx.coroutines.launch
import java.io.File
import java.util.Calendar
import java.util.Date

private enum class Screen { Map, RecordVideo, Settings }

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as DailyMapLineApp
        if (app.recordingEnabled && hasLocationPermission()) startRecording()
        setContent { MaterialTheme { Root(app) } }
    }

    fun hasLocationPermission() =
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    fun startRecording() = ContextCompat.startForegroundService(this, Intent(this, RecordingService::class.java))
    fun stopRecording() = stopService(Intent(this, RecordingService::class.java))
}

@Composable
private fun Root(app: DailyMapLineApp) {
    // Saveable: Android may kill the process while a picker is open, and the result must return to the same screen.
    var screen by rememberSaveable { mutableStateOf(Screen.Map) }
    var showIntro by rememberSaveable { mutableStateOf(!app.didShowIntro) }
    val error by app.errorMessage.collectAsState()
    BackHandler(screen != Screen.Map) { screen = Screen.Map }
    Surface(Modifier.fillMaxSize().systemBarsPadding()) {
        when (screen) {
            Screen.Map -> MapScreen(app, onVideo = { screen = Screen.RecordVideo }, onSettings = { screen = Screen.Settings })
            Screen.RecordVideo -> RecordVideoScreen(app) { screen = Screen.Map }
            Screen.Settings -> SettingsScreen(app) { screen = Screen.Map }
        }
    }
    if (showIntro) IntroDialog(app) { app.didShowIntro = true; showIntro = false }
    error?.let { message ->
        AlertDialog(
            onDismissRequest = { app.errorMessage.value = null },
            confirmButton = { TextButton({ app.errorMessage.value = null }) { Text("확인") } },
            title = { Text("오류") },
            text = { Text(message) },
        )
    }
}

/** Starts recording after asking for permission; the toggle and intro share this. */
@Composable
private fun rememberRecordingToggle(app: DailyMapLineApp): (Boolean) -> Unit {
    val activity = LocalContext.current as MainActivity
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        if (result[Manifest.permission.ACCESS_FINE_LOCATION] == true) activity.startRecording() else app.status.value = RecordingStatus.Denied
    }
    return { enabled ->
        app.recordingEnabled = enabled
        if (!enabled) {
            activity.stopRecording()
            app.pendingGap = true
            app.status.value = RecordingStatus.Off
        } else if (activity.hasLocationPermission()) {
            activity.startRecording()
        } else {
            app.status.value = RecordingStatus.WaitingPermission
            val permissions = buildList {
                add(Manifest.permission.ACCESS_FINE_LOCATION)
                add(Manifest.permission.ACCESS_COARSE_LOCATION)
                if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
            }
            launcher.launch(permissions.toTypedArray())
        }
    }
}

@Composable
private fun IntroDialog(app: DailyMapLineApp, onDone: () -> Unit) {
    val toggle = rememberRecordingToggle(app)
    AlertDialog(
        onDismissRequest = onDone,
        title = { Text("이동을 기록해 기록영상으로 만들어요") },
        text = {
            Text("위치 기록을 켜면 앱을 닫아 둔 동안에도 알림을 띄우고 이동을 기록해요. 운영체제 상황에 따라 기록 간격은 달라질 수 있어요.\n\n기록은 이 기기에만 저장하고 서버로 보내지 않아요. 기록을 끄면 새 위치를 저장하지 않아요.")
        },
        confirmButton = { Button({ toggle(true); onDone() }) { Text("위치 기록 켜기") } },
        dismissButton = { TextButton(onDone) { Text("지도만 보기") } },
    )
}

@SuppressLint("MissingPermission")
@Composable
private fun MapScreen(app: DailyMapLineApp, onVideo: () -> Unit, onSettings: () -> Unit) {
    val activity = LocalContext.current as MainActivity
    val branches by app.branches.collectAsState()
    val livePath by app.livePath.collectAsState()
    val status by app.status.collectAsState()
    val location by app.currentLocation.collectAsState()
    val ready by app.dataReady.collectAsState()
    var recenter by remember { mutableIntStateOf(0) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) recenter++ else app.errorMessage.value = "현재 위치를 보려면 설정에서 위치 권한을 허용해 주세요."
    }
    // For showing the current position only. Nothing is recorded unless recording is on.
    DisposableEffect(activity.hasLocationPermission(), recenter) {
        val manager = activity.getSystemService(LocationManager::class.java)
        val listener = LocationListener { if (!app.recordingEnabled) app.currentLocation.value = it }
        if (activity.hasLocationPermission()) manager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 2_000L, 0f, listener)
        onDispose { manager.removeUpdates(listener) }
    }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onVideo) { Text("영상 만들기") }
            Spacer(Modifier.weight(1f))
            OutlinedButton(onSettings) { Text("설정") }
        }
        Text(if (ready) status.text else "지도와 길 데이터를 준비하고 있어요.", Modifier.padding(horizontal = 12.dp, vertical = 4.dp), fontSize = 14.sp)
        Box(Modifier.fillMaxSize()) {
            if (ready) VisitedMap(branches, livePath, location, recenter, Modifier.fillMaxSize())
            Text(
                "Protomaps © OpenStreetMap",
                Modifier.align(Alignment.BottomStart).padding(8.dp).background(Color.White.copy(alpha = 0.9f)).padding(4.dp),
                fontSize = 11.sp,
            )
            Box(
                Modifier.align(Alignment.BottomEnd).padding(16.dp).size(48.dp).clip(CircleShape).background(Color.White)
                    .semantics { contentDescription = "현위치" }
                    .clickable { if (activity.hasLocationPermission()) recenter++ else permission.launch(Manifest.permission.ACCESS_FINE_LOCATION) },
                contentAlignment = Alignment.Center,
            ) { Text("◎", fontSize = 22.sp, color = Color(0xFF247DDD)) }
        }
    }
}

@Composable
private fun SettingsScreen(app: DailyMapLineApp, onBack: () -> Unit) {
    val context = LocalContext.current
    val status by app.status.collectAsState()
    var enabled by remember { mutableStateOf(app.recordingEnabled) }
    val toggle = rememberRecordingToggle(app)
    var message by remember { mutableStateOf<String?>(null) }
    var pending by remember { mutableStateOf<Pair<ByteArray, BackupSummary>?>(null) }
    val exporter = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        message = runCatching {
            context.contentResolver.openOutputStream(uri)!!.use { it.write(app.store.exportBackup()) }
            "기록을 내보냈어요."
        }.getOrDefault("내보내지 못했어요. 기록은 그대로예요.")
    }
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        runCatching {
            val data = context.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
            pending = data to RecordStore.inspectBackup(data)
            message = null
        }.onFailure { message = (it as? StoreException)?.message ?: "파일을 읽지 못했어요." }
    }
    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        TextButton(onBack) { Text("‹ 지도 화면") }
        Text("설정", fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("위치 기록", Modifier.weight(1f))
            Switch(enabled, { enabled = it; toggle(it) })
        }
        Text(status.text, fontSize = 13.sp, color = Color.Gray)
        HorizontalDivider()
        Text("백업", fontWeight = FontWeight.Bold)
        Button({ exporter.launch("DailyMapLine-${DailyMapLineApp.localDate(Date())}.dmlbackup") }) { Text("기록 내보내기") }
        Button({ importer.launch(arrayOf("*/*")) }) { Text("기록 가져오기") }
        Text("백업 파일은 암호화되지 않아요. 파일을 가진 사람은 이동 기록을 볼 수 있으니 안전한 곳에 보관해 주세요.", fontSize = 13.sp, color = Color.Gray)
        message?.let { Text(it, fontSize = 13.sp) }
    }
    pending?.let { (data, summary) ->
        AlertDialog(
            onDismissRequest = { pending = null },
            title = { Text("현재 기록을 모두 교체할까요?") },
            text = { Text("현재 노드 ${app.store.nodeCount()}개를 지우고, 백업의 ${summary.dates.size}일치 기록(노드 ${summary.nodeCount}개, 브랜치 ${summary.branchCount}개)으로 바꿔요. 되돌릴 수 없어요.") },
            confirmButton = { TextButton({ if (app.restoreBackup(data)) message = "백업을 복원했어요."; pending = null }) { Text("교체", color = Color.Red) } },
            dismissButton = { TextButton({ pending = null }) { Text("취소") } },
        )
    }
}

/** One month. Only recorded dates can be picked. */
@Composable
private fun MonthPicker(title: String, recorded: Set<String>, selection: String?, onSelect: (String) -> Unit) {
    var month by remember { mutableStateOf(Calendar.getInstance().apply { set(Calendar.DAY_OF_MONTH, 1) }.timeInMillis) }
    val calendar = Calendar.getInstance().apply { timeInMillis = month }
    val leading = calendar.get(Calendar.DAY_OF_WEEK) - 1
    val count = calendar.getActualMaximum(Calendar.DAY_OF_MONTH)
    val cells = List(leading) { null } + (0 until count).map { day -> Calendar.getInstance().apply { timeInMillis = month; add(Calendar.DAY_OF_MONTH, day) }.time }
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
        Text(title, fontWeight = FontWeight.Bold)
        Text(selection ?: "날짜 선택", fontSize = 12.sp, color = Color.Gray)
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton({ month = Calendar.getInstance().apply { timeInMillis = month; add(Calendar.MONTH, -1) }.timeInMillis }, Modifier.semantics { contentDescription = "$title 이전 달" }) { Text("‹") }
            Text("${calendar.get(Calendar.YEAR)}년 ${calendar.get(Calendar.MONTH) + 1}월", Modifier.weight(1f), fontWeight = FontWeight.Bold, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            TextButton({ month = Calendar.getInstance().apply { timeInMillis = month; add(Calendar.MONTH, 1) }.timeInMillis }, Modifier.semantics { contentDescription = "$title 다음 달" }) { Text("›") }
        }
        Row { listOf("일", "월", "화", "수", "목", "금", "토").forEach { Text(it, Modifier.weight(1f), fontSize = 12.sp, color = Color.Gray, textAlign = androidx.compose.ui.text.style.TextAlign.Center) } }
        cells.chunked(7).forEach { week ->
            Row {
                for (i in 0 until 7) {
                    val day = week.getOrNull(i)
                    Box(Modifier.weight(1f).height(44.dp).padding(1.dp), contentAlignment = Alignment.Center) {
                        if (day != null) {
                            val date = DailyMapLineApp.localDate(day)
                            val number = Calendar.getInstance().apply { time = day }.get(Calendar.DAY_OF_MONTH).toString()
                            if (date in recorded) {
                                val selected = selection == date
                                Box(
                                    Modifier.fillMaxSize().clip(RoundedCornerShape(6.dp))
                                        .background(if (selected) Color(0xFF247DDD) else Color(0x2E247DDD))
                                        .semantics { contentDescription = "$title $date 기록 있음" }
                                        .clickable { onSelect(date) },
                                    contentAlignment = Alignment.Center,
                                ) { Text(number, color = if (selected) Color.White else Color(0xFF247DDD)) }
                            } else {
                                Text(number, color = Color.LightGray)
                            }
                        }
                    }
                }
            }
        }
    }
}

private sealed interface Phase {
    data object Setup : Phase
    data class Rendering(val progress: Float) : Phase
    data class Preview(val file: File) : Phase
    data class Failed(val message: String) : Phase
}

@Composable
private fun RecordVideoScreen(app: DailyMapLineApp, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val dates by app.dates.collectAsState()
    var start by remember { mutableStateOf<String?>(null) }
    var end by remember { mutableStateOf<String?>(null) }
    var phase by remember { mutableStateOf<Phase>(Phase.Setup) }
    var saveMessage by remember { mutableStateOf<String?>(null) }
    var deletion by remember { mutableStateOf<DeletionPreview?>(null) }
    val valid = start != null && end != null && start!! <= end!!
    val branches: List<Branch> = remember(start, end, dates) { if (valid) app.store.branches(start!!, end!!) else emptyList() }
    val timeline = remember(branches) { VideoTimeline(branches) }
    val label = if (start == end) start.orEmpty() else "$start – $end"
    // Deletion stays per date, so it is offered only when one date is selected.
    val singleDate = start?.takeIf { end == null || end == it }

    fun render() {
        phase = Phase.Rendering(0f)
        scope.launch {
            phase = runCatching { Phase.Preview(VideoRenderer.render(context, label, timeline) { phase = Phase.Rendering(it) }) }
                .getOrElse { Phase.Failed("기록영상을 만들지 못했어요. 원본 기록은 그대로예요. ${it.message}") }
        }
    }

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onBack) { Text("‹ 지도 화면") }
            Text("기록영상", Modifier.weight(1f), fontWeight = FontWeight.Bold)
            if (phase == Phase.Setup && singleDate != null) {
                TextButton({ deletion = app.store.deletionPreview(singleDate) }) { Text("삭제", color = Color.Red) }
            }
        }
        when (val current = phase) {
            Phase.Setup -> Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                MonthPicker("시작", dates, start) { start = it }
                HorizontalDivider()
                MonthPicker("종료", dates, end) { end = it }
                when {
                    dates.isEmpty() -> Text("아직 기록이 없어요.", fontSize = 13.sp)
                    start != null && end != null && !valid -> Text("종료 날짜는 시작 날짜와 같거나 뒤여야 해요.", fontSize = 13.sp)
                    valid && timeline.lengthMeters <= 0 -> Text("기록영상을 만들 수 있는 이동 경로가 없어요.", fontSize = 13.sp)
                }
                if (timeline.lengthMeters > 0) {
                    RecordRouteMap(branches, Modifier.fillMaxWidth().height(220.dp))
                    Text(String.format("길이 %.2f km · 기록영상 %.0f초", timeline.lengthMeters / 1000, timeline.durationSeconds))
                }
                Button(::render, Modifier.align(Alignment.CenterHorizontally), enabled = timeline.lengthMeters > 0) { Text("기록영상 만들기") }
            }
            is Phase.Rendering -> Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.Center) {
                LinearProgressIndicator({ current.progress }, Modifier.fillMaxWidth())
                Text("휴대폰에서 기록영상을 만들고 있어요.", Modifier.padding(top = 12.dp))
            }
            is Phase.Preview -> Column(Modifier.fillMaxSize().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                val player = remember(current.file) {
                    ExoPlayer.Builder(context).build().apply { setMediaItem(MediaItem.fromUri(Uri.fromFile(current.file))); prepare(); play() }
                }
                DisposableEffect(player) { onDispose { player.release() } }
                AndroidView({ PlayerView(it).apply { this.player = player } }, Modifier.weight(1f).aspectRatio(9f / 16f))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(top = 12.dp)) {
                    Button({ saveMessage = save(context, current.file) }) { Text("영상 다운로드") }
                    OutlinedButton({ share(context, current.file) }) { Text("공유") }
                }
                saveMessage?.let { Text(it, fontSize = 13.sp) }
                TextButton({ saveMessage = null; phase = Phase.Setup }) { Text("날짜 다시 고르기") }
            }
            is Phase.Failed -> Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.Center) {
                Text(current.message)
                Button(::render) { Text("다시 시도") }
                TextButton({ phase = Phase.Setup }) { Text("날짜 다시 고르기") }
            }
        }
    }
    deletion?.let { preview ->
        val lines = buildList {
            add("노드 ${preview.deletedNodes}개와 브랜치 ${preview.deletedBranches}개를 삭제해요. 되돌릴 수 없어요.")
            if (preview.retainedNodes > 0) {
                val referenced = preview.referencedBy.joinToString(", ")
                add("이 날의 위치 ${preview.retainedNodes}곳은 $referenced 기록영상의 시작점이라 남아요. $referenced 기록을 삭제하면 함께 지워져요.")
            }
            add("사진에 저장했거나 공유한 기록영상은 지워지지 않아요.")
        }
        AlertDialog(
            onDismissRequest = { deletion = null },
            title = { Text("$singleDate 기록을 삭제할까요?") },
            text = { Text(lines.joinToString("\n\n")) },
            confirmButton = { TextButton({ if (singleDate != null && app.deleteDay(singleDate)) { start = null; end = null }; deletion = null }) { Text("삭제", color = Color.Red) } },
            dismissButton = { TextButton({ deletion = null }) { Text("취소") } },
        )
    }
}

private fun save(context: android.content.Context, file: File): String = runCatching {
    val values = ContentValues().apply {
        put(MediaStore.Video.Media.DISPLAY_NAME, file.name)
        put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
        if (Build.VERSION.SDK_INT >= 29) put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/DailyMapLine")
    }
    val uri = context.contentResolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)!!
    context.contentResolver.openOutputStream(uri)!!.use { out -> file.inputStream().use { it.copyTo(out) } }
    "동영상 보관함에 저장했어요."
}.getOrDefault("기록영상을 저장하지 못했어요. 저장 공간과 권한을 확인해 주세요.")

private fun share(context: android.content.Context, file: File) {
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    val intent = Intent(Intent.ACTION_SEND).setType("video/mp4").putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(intent, "공유"))
}
