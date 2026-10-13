package app.ayumitra.ayumitra

import android.content.Context
import android.content.Intent
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Foreground-processing gate for user-initiated local work (Sub-owned).
 *
 * MethodChannel `app.ayumitra/processing`: `begin -> Bool`,
 * `end -> void`, `status -> Map`. No arguments are accepted, so no health
 * strings can enter; `begin` returns whether the task was accepted.
 * `status` reports `{active, wakeHeld, timedOut}` booleans only.
 *
 * begin/end are idempotent under one lock: a second begin while active is a
 * no-op success, and a generation token per begin lets the service reject a
 * late onStart after end() already ran, so no orphan wake lock or
 * notification survives cancellation. The partial wake lock lives only in
 * the service and is released in finally-style paths (end, destroy, task
 * removal, system timeout). No network, no cloud, no boot receiver, and the
 * model/voice bridges are untouched.
 */
object LocalProcessingBridge {
    private const val CHANNEL = "app.ayumitra/processing"
    private const val TAG = "LocalProcessingBridge"

    private var appContext: Context? = null
    private val lock = Any()
    private var active = false
    private var generation = 0
    private var timedOut = false
    private var wakeHeld = false

    fun register(flutterEngine: FlutterEngine, activity: android.app.Activity) {
        appContext = activity.applicationContext
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "begin" -> result.success(begin())
                    "end" -> {
                        end()
                        result.success(null)
                    }
                    "status" -> result.success(status())
                    else -> result.notImplemented()
                }
            }
    }

    private fun begin(): Boolean {
        val request: Intent
        val token: Int
        val context: Context
        synchronized(lock) {
            if (active) return true
            context = appContext ?: return false
            active = true
            timedOut = false
            generation++
            token = generation
            request = Intent(context, LocalProcessingService::class.java).putExtra(
                LocalProcessingService.EXTRA_GENERATION,
                token,
            )
        }
        // Binder IPC outside the lock: status/end/claimStart never stall
        // behind the activity-manager call.
        return try {
            context.startForegroundService(request)
            Log.i(TAG, "begin")
            true
        } catch (e: Exception) {
            Log.e(TAG, "begin: ${e.javaClass.simpleName}")
            synchronized(lock) {
                // Roll back only our own optimistic claim; a newer
                // begin/end cycle owns the state now.
                if (active && generation == token) {
                    active = false
                    generation++
                }
            }
            false
        }
    }

    private fun end() {
        val context: Context?
        synchronized(lock) {
            if (!active) return
            active = false
            // Mirror the intended state now; the service releases the
            // hardware lock in onDestroy and its stale token cannot clobber.
            wakeHeld = false
            generation++
            context = appContext
        }
        try {
            context?.stopService(
                Intent(context, LocalProcessingService::class.java),
            )
        } catch (e: Exception) {
            Log.e(TAG, "end: ${e.javaClass.simpleName}")
        }
        Log.i(TAG, "end")
    }

    private fun status(): Map<String, Boolean> = synchronized(lock) {
        mapOf(
            "active" to active,
            "wakeHeld" to wakeHeld,
            "timedOut" to timedOut,
        )
    }

    // Service-side hooks below. Every callback carries the generation token
    // the service bound at its claimed onStart; state changes apply only
    // when the token still matches, so an old generation's destroy can never
    // clobber a live one. The service owns the wake lock; the bridge only
    // mirrors booleans so status() never blocks on hardware.

    /** Returns true only when [token] matches the current live task. */
    fun claimStart(token: Int): Boolean = synchronized(lock) {
        active && token == generation
    }

    fun noteWakeHeld(token: Int, held: Boolean) {
        synchronized(lock) {
            if (token == generation) wakeHeld = held
        }
    }

    fun noteStopped(token: Int) {
        synchronized(lock) {
            if (token == generation) {
                active = false
                wakeHeld = false
            }
        }
    }

    fun noteTimeout(token: Int) {
        synchronized(lock) {
            if (token == generation) {
                timedOut = true
                active = false
                wakeHeld = false
            }
        }
    }
}
