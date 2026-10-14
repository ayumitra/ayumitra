package app.ayumitra.ayumitra

import android.app.Activity
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Device-only screenshot/recents protection, independent of auth decisions. */
object AppPrivacyBridge {
    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.ayumitra/app_lock")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setPrivacyEnabled" -> {
                        val enabled = (call.arguments as? Map<*, *>)?.get("enabled") as? Boolean
                        if (enabled == null) {
                            result.error("BAD_ARGUMENT", "A privacy setting is required.", null)
                        } else {
                            // Startup is secure until Dart restores the persisted preference.
                            if (enabled) {
                                activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            } else {
                                activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            }
                            result.success(true)
                        }
                    }
                    "setPrivacyVisible" -> {
                        val visible = (call.arguments as? Map<*, *>)?.get("visible") as? Boolean
                        if (visible == null) {
                            result.error("BAD_ARGUMENT", "A privacy visibility setting is required.", null)
                        } else {
                            // Android uses FLAG_SECURE for snapshots; Flutter owns the lock UI.
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
