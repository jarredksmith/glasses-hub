package com.jarredsmith.glasseshub

import android.Manifest
import android.app.Application
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

class HubApp : Application() {
    lateinit var model: HubModel; private set
    override fun onCreate() {
        super.onCreate()
        model = HubModel(this)
        instance = this
    }
    companion object { var instance: HubApp? = null; private set }
}

/**
 * Keeps the app running while the glasses' display is on and the phone's screen is off. Android stops
 * apps it can't see unless they show a notification saying what they're doing; this is that notification.
 */
class HubService : Service() {
    private var lock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "stop") {
            HubApp.instance?.model?.stopDisplay()
            return START_NOT_STICKY
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, HubService::class.java).setAction("stop"), PendingIntent.FLAG_IMMUTABLE)
        val note: Notification = NotificationCompat.Builder(this, "running").setSmallIcon(R.drawable.ic_glasses)
            .setContentTitle("Glasses Hub is on").setContentText("Showing on your glasses. Tap to open.")
            .setOngoing(true).setContentIntent(open).addAction(0, "Turn off", stop).build()
        var type = 0
        if (Build.VERSION.SDK_INT >= 29) {
            type = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            if (intent?.getBooleanExtra("mic", false) == true && Build.VERSION.SDK_INT >= 30 && granted(this, Manifest.permission.RECORD_AUDIO)) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            if (intent?.getBooleanExtra("location", false) == true && (granted(this, Manifest.permission.ACCESS_FINE_LOCATION) || granted(this, Manifest.permission.ACCESS_COARSE_LOCATION))) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
        }
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(7, note, type) else startForeground(7, note)
        } catch (e: Exception) {
            // The phone wouldn't allow it (started from the background, or a permission is missing). The
            // display still works while the app is open.
            try { if (Build.VERSION.SDK_INT >= 29) startForeground(7, note, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE) } catch (e: Exception) { stopSelf(); return START_NOT_STICKY }
        }
        if (lock == null) {
            lock = (getSystemService(Context.POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "glasseshub:display").also {
                it.setReferenceCounted(false)
                try { it.acquire(12 * 60 * 60 * 1000L) } catch (e: Exception) {}
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        try { lock?.release() } catch (e: Exception) {}
        lock = null
        super.onDestroy()
    }

    companion object {
        private var state = ""
        /** Turns the keep-running notification on or off, and says which sensors are in use. */
        fun set(context: Context, on: Boolean, mic: Boolean, location: Boolean) {
            val wanted = if (on) "on|$mic|$location" else ""
            if (wanted == state) return
            state = wanted
            val intent = Intent(context, HubService::class.java).putExtra("mic", mic).putExtra("location", location)
            try {
                if (on) { if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent) }
                else context.stopService(intent)
            } catch (e: Exception) { state = "" }
        }
    }
}

/**
 * Reads the phone's notifications as they arrive, so they can be shown on the glasses. The glasses turn
 * notifications away while a caption page is up; this puts them on Glasses Hub's own page instead.
 */
class NoticeListener : NotificationListenerService() {
    override fun onListenerConnected() { connected = true }
    override fun onListenerDisconnected() { connected = false }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val posted = sbn ?: return
        val model = HubApp.instance?.model ?: return
        if (posted.packageName == packageName || posted.isOngoing) return
        val note = posted.notification ?: return
        if (note.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val extras = note.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim() ?: ""
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString()?.trim() ?: ""
        if (title.isEmpty() && text.isEmpty()) return
        val key = posted.packageName + "|" + title + "|" + text
        if (key == lastKey && System.currentTimeMillis() - lastAt < 4000) return       // apps often post the same thing twice
        lastKey = key; lastAt = System.currentTimeMillis()
        val app = try { packageManager.getApplicationLabel(packageManager.getApplicationInfo(posted.packageName, 0)).toString() } catch (e: Exception) { com.jarredsmith.glasseshub.core.AppNames.name(posted.packageName) }
        mainHandler.post { model.phoneNotice(posted.packageName, app, title, text) }
    }

    companion object {
        @Volatile var connected = false; private set
        private var lastKey = ""
        private var lastAt = 0L
        /** Whether the wearer has let Glasses Hub read notifications, in the phone's settings. */
        fun allowed(context: Context): Boolean = NotificationManagerCompat.getEnabledListenerPackages(context).contains(context.packageName)
        fun component(context: Context) = ComponentName(context, NoticeListener::class.java)
    }
}
