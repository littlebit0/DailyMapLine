package com.kimhwi.dailymapline

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.IBinder

/** Foreground service so recording continues in the background, as Android requires for location. */
class RecordingService : Service(), LocationListener {
    private val app get() = application as DailyMapLineApp
    private val manager get() = getSystemService(LocationManager::class.java)

    override fun onBind(intent: Intent?): IBinder? = null

    @SuppressLint("MissingPermission")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val channel = NotificationChannel(CHANNEL, "위치 기록", NotificationManager.IMPORTANCE_LOW)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        val notification = Notification.Builder(this, CHANNEL)
            .setContentTitle("DailyMapLine")
            .setContentText("이동을 기록하고 있어요. 기록은 이 기기에만 저장해요.")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(1, notification)
        }
        runCatching {
            manager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 5_000L, 0f, this)
        }.onFailure {
            app.status.value = RecordingStatus.Denied
            stopSelf()
        }
        return START_STICKY
    }

    override fun onLocationChanged(location: Location) = app.handle(location)

    override fun onProviderDisabled(provider: String) {
        app.status.value = RecordingStatus.NoSignal
    }

    override fun onDestroy() {
        manager.removeUpdates(this)
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "recording"
    }
}
