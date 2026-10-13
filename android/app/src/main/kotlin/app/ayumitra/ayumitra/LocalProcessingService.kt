package app.ayumitra.ayumitra

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log

/**
 * Foreground dataSync service for user-initiated local work (Sub-owned).
 *
 * Started only from [LocalProcessingBridge.begin]; never from boot, never
 * from the background. Holds a partial wake lock only for the actual task
 * with a bounded 30-minute acquisition timeout, and shows one quiet ongoing
 * notification with generic wording. START_NOT_STICKY: if the process dies,
 * no fake running job is resurrected. A late onStart after the bridge
 * already ended the task stops immediately without notification or wake.
 */
class LocalProcessingService : Service() {
    companion object {
        const val EXTRA_GENERATION = "generation"
        private const val NOTIFICATION_ID = 4401
        private const val CHANNEL_ID = "ayumitra_local_processing"
        private const val WAKE_TIMEOUT_MS = 30 * 60 * 1000L
        private const val TAG = "LocalProcessingService"
    }

    private var wakeLock: PowerManager.WakeLock? = null
    // Generation bound at the claimed onStart. Every state callback carries
    // it, so an old service instance can never clobber a newer generation.
    private var boundToken: Int = -1
    private val handler = Handler(Looper.getMainLooper())
    private var deadline: Runnable? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val token = intent?.getIntExtra(EXTRA_GENERATION, -1) ?: -1
        // Cancellation that arrived before this start must not orphan a wake
        // lock or a notification. stopSelf(startId) only stops when no newer
        // start exists, so a late old start can never kill a new generation.
        if (!LocalProcessingBridge.claimStart(token)) {
            // startId describes arrival order, not generation order. An old
            // intent arriving after a live new generation must not stop it.
            if (!LocalProcessingBridge.claimStart(boundToken)) stopSelf(startId)
            return START_NOT_STICKY
        }
        boundToken = token
        try {
            ensureChannel()
            startForeground(
                NOTIFICATION_ID,
                notification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
            // A new claim always gets a fresh full wake window: drop any
            // lock held over from a torn-down generation first, so one
            // field, one release, and no inherited remaining timeout.
            releaseWake()
            acquireWake()
            scheduleDeadline()
        } catch (e: Exception) {
            Log.e(TAG, "start: ${e.javaClass.simpleName}")
            LocalProcessingBridge.noteStopped(boundToken)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        LocalProcessingBridge.noteStopped(boundToken)
        cancelDeadline()
        releaseWake()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        cancelDeadline()
        LocalProcessingBridge.noteTimeout(boundToken)
        releaseWake()
        stopSelf()
    }

    override fun onDestroy() {
        cancelDeadline()
        // Token-guarded: a stale instance ending after a newer generation
        // began must not clear live state; a live generation ending here is
        // correctly reflected as inactive.
        LocalProcessingBridge.noteStopped(boundToken)
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (e: Exception) {
            Log.e(TAG, "foreground remove: ${e.javaClass.simpleName}")
        }
        releaseWake()
        super.onDestroy()
    }

    /**
     * Pairs the bounded wake acquisition with a matching deadline: when
     * protection expires, the service marks timed-out, drops the lock and
     * itself, so status can never claim a live service on an expired lock.
     * This ends processing protection only — never model work explicitly;
     * Dart-side records and job attempts persist independently. Cancelled on
     * end (via destroy), task removal, timeout, and any new claimed start.
     */
    private fun scheduleDeadline() {
        cancelDeadline()
        val task = Runnable {
            deadline = null
            LocalProcessingBridge.noteTimeout(boundToken)
            releaseWake()
            try {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } catch (e: Exception) {
                Log.e(TAG, "foreground remove: ${e.javaClass.simpleName}")
            }
            stopSelf()
        }
        deadline = task
        handler.postDelayed(task, WAKE_TIMEOUT_MS)
    }

    private fun cancelDeadline() {
        deadline?.let { handler.removeCallbacks(it) }
        deadline = null
    }

    private fun ensureChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        if (manager?.getNotificationChannel(CHANNEL_ID) == null) {
            manager?.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Local processing",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
    }

    private fun notification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Ayumitra is processing locally")
            .setContentText("Your records stay on this device")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(openApp)
            .setOngoing(true)
            .build()
    }

    private fun acquireWake() {
        val manager = getSystemService(Context.POWER_SERVICE) as PowerManager
        val lock = manager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "Ayumitra:processing",
        )
        // Bounded backstop: the lock auto-releases, the model work is never
        // force-terminated by this timeout.
        lock.acquire(WAKE_TIMEOUT_MS)
        wakeLock = lock
        LocalProcessingBridge.noteWakeHeld(boundToken, true)
    }

    private fun releaseWake() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (e: Exception) {
            Log.e(TAG, "wake release: ${e.javaClass.simpleName}")
        }
        wakeLock = null
        LocalProcessingBridge.noteWakeHeld(boundToken, false)
    }
}
