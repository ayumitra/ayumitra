package app.ayumitra.ayumitra

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * Strict on-device English speech bridge (Sub-owned file).
 *
 * Channels:
 * - MethodChannel `app.ayumitra/voice`: `capabilities -> Map`,
 *   `requestPermission -> Bool`, `start {sessionId: 64-bit int} -> void`,
 *   `stop -> void`. Every partial/final/error/stopped event echoes the
 *   starting call's `sessionId` (captured per session, never re-read from
 *   mutable state when a queued callback runs); invalid `start` args fail
 *   the method with BAD_SESSION_ID and start no session.
 * - EventChannel `app.ayumitra/voice_events`: maps with
 *   `type` in {partial, final, error, stopped} plus optional
 *   `text`, `code`, `reason`.
 *
 * Hard rules (fail closed, never fall back):
 * - API 31+ `isOnDeviceRecognitionAvailable` + `createOnDeviceSpeechRecognizer`
 *   only. `createSpeechRecognizer` is never used: no network recognizer,
 *   no network audio, no model download.
 * - en-US with `EXTRA_PREFER_OFFLINE`; API 33+ additionally preflights
 *   installed on-device English via `checkRecognitionSupport` and starts
 *   listening with an actually installed English locale (device-default
 *   English if installed, else en-US, else another installed English
 *   locale) — never an assumed en-US. Below API 33 the en-US default stands.
 * - Microphone is requested only from `requestPermission`, which Dart calls
 *   after an explicit user start/wake toggle. Never auto-prompted on `start`.
 * - No background service, no audio files, no transcript logs: lifecycle and
 *   error logs carry codes only, never recognized text.
 * - `final`/`stopped` are emitted exactly once per session; recognition
 *   generation ids drop stale listener and preflight callbacks.
 * - The listener is installed before any recognizer command.
 */
object LocalVoiceBridge {
    private const val CHANNEL = "app.ayumitra/voice"
    private const val EVENTS = "app.ayumitra/voice_events"
    private const val TAG = "LocalVoiceBridge"
    private const val LANGUAGE = "en-US"
    private const val MIC_REQUEST_CODE = 4411
    private const val PLATFORM = "android"

    private var appContext: Context? = null
    private var hostActivity: Activity? = null
    private var eventSink: EventChannel.EventSink? = null
    private var recognizer: SpeechRecognizer? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var generation = 0
    private var sessionActive = false
    // 64-bit end to end: Dart session ids are microsecondsSinceEpoch and
    // exceed Int range. Independent generation guards stay Int.
    private var activeSessionId: Long? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        appContext = activity.applicationContext
        hostActivity = activity
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capabilities" -> result.success(capabilities())
                    "requestPermission" -> requestMicPermission(result)
                    "start" -> {
                        val sessionId = sessionArg(call)
                        if (sessionId == null) {
                            result.error(
                                "BAD_SESSION_ID",
                                "start requires an int sessionId.",
                                null,
                            )
                        } else {
                            startSession(sessionId)
                            result.success(null)
                        }
                    }
                    "stop" -> {
                        stopSession(reason = null)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS)
            .setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                        eventSink = events
                    }
                    override fun onCancel(arguments: Any?) {
                        // Dart is gone: release the mic without emitting.
                        eventSink = null
                        endSessionSilently()
                    }
                },
            )
    }

    // Called from MainActivity permission + lifecycle hooks.
    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != MIC_REQUEST_CODE) return false
        val pending = pendingPermissionResult ?: return true
        pendingPermissionResult = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pending.success(granted)
        return true
    }

    fun onHostPause() = stopSession(reason = "Activity paused — microphone released.")

    fun onHostDestroy() {
        // Resolve a dangling permission future so Dart never hangs on it.
        val pending = pendingPermissionResult
        pendingPermissionResult = null
        pending?.error(
            "ACTIVITY_DESTROYED",
            "The app screen was destroyed before microphone permission completed.",
            null,
        )
        stopSession(reason = "Activity destroyed — microphone released.")
        hostActivity = null
        appContext = null
    }

    private fun capabilities(): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < 31) {
            return mapOf(
                "available" to false,
                "onDevice" to false,
                "platform" to PLATFORM,
                "reason" to "On-device speech recognition requires Android 12 or newer.",
            )
        }
        val context = appContext
        val available = try {
            context != null && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        } catch (e: Exception) {
            Log.e(TAG, "capabilities check: ${e.javaClass.simpleName}")
            false
        }
        if (!available) {
            return mapOf(
                "available" to false,
                "onDevice" to false,
                "platform" to PLATFORM,
                "reason" to "No on-device speech recognition service with English is installed.",
            )
        }
        return mapOf("available" to true, "onDevice" to true, "platform" to PLATFORM)
    }

    private fun hasMicPermission(): Boolean {
        val activity = hostActivity ?: return false
        return activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun requestMicPermission(result: MethodChannel.Result) {
        val activity = hostActivity
        if (activity == null || activity.isFinishing) {
            result.error("NO_ACTIVITY", "The app screen is not available.", null)
            return
        }
        if (hasMicPermission()) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            result.error(
                "PERMISSION_PENDING",
                "A microphone permission request is already in flight.",
                null,
            )
            return
        }
        pendingPermissionResult = result
        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_REQUEST_CODE)
    }

    private fun sessionArg(call: MethodCall): Long? {
        // StandardMessageCodec may decode a Dart int as Int or Long; Dart
        // session ids need the full 64-bit range either way.
        return when (val raw = call.argument<Any>("sessionId")) {
            is Long -> raw
            is Int -> raw.toLong()
            else -> null
        }
    }

    private fun startSession(sessionId: Long) {
        val context = appContext
        if (Build.VERSION.SDK_INT < 31 || context == null) {
            emit(
                mapOf(
                    "type" to "error",
                    "sessionId" to sessionId,
                    "code" to "NOT_AVAILABLE",
                    "reason" to "On-device speech recognition requires Android 12 or newer.",
                ),
            )
            return
        }
        if (!onDeviceReady(context)) {
            emit(
                mapOf(
                    "type" to "error",
                    "sessionId" to sessionId,
                    "code" to "NOT_AVAILABLE",
                    "reason" to "No on-device speech recognition service with English is installed.",
                ),
            )
            return
        }
        if (!hasMicPermission()) {
            emit(
                mapOf(
                    "type" to "error",
                    "sessionId" to sessionId,
                    "code" to "PERMISSION_REQUIRED",
                    "reason" to "Microphone permission was not granted. Call requestPermission after an explicit user action.",
                ),
            )
            return
        }
        if (sessionActive) {
            emit(
                mapOf(
                    "type" to "error",
                    "sessionId" to sessionId,
                    "code" to "ALREADY_ACTIVE",
                    "reason" to "A voice session is already running.",
                ),
            )
            return
        }
        val myGeneration = ++generation
        sessionActive = true
        activeSessionId = sessionId
        val current = try {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } catch (e: Exception) {
            Log.e(TAG, "recognizer create: ${e.javaClass.simpleName}")
            failSession(
                myGeneration,
                "RECOGNIZER_UNAVAILABLE",
                "The on-device recognizer could not be created.",
            )
            return
        }
        recognizer = current
        // Listener is installed before any recognizer command.
        current.setRecognitionListener(VoiceListener(myGeneration, sessionId))
        if (Build.VERSION.SDK_INT >= 33) {
            preflightEnglish(current, myGeneration)
        } else {
            // No support query below API 33: the en-US default stands.
            beginListening(current, myGeneration, LANGUAGE)
        }
    }

    private fun onDeviceReady(context: Context): Boolean {
        return try {
            SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        } catch (e: Exception) {
            Log.e(TAG, "availability check: ${e.javaClass.simpleName}")
            false
        }
    }

    private fun listenIntent(locale: String = LANGUAGE): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            if (Build.VERSION.SDK_INT >= 33) {
                // Local hints for Ayu, pronounced aa-yuh. No fuzzy or
                // generic "are you" wake matching and no cloud path.
                putStringArrayListExtra(
                    RecognizerIntent.EXTRA_BIASING_STRINGS,
                    arrayListOf("Ayu", "Aayu", "Ayuh", "Hey Ayu"),
                )
            }
        }

    private fun preflightEnglish(current: SpeechRecognizer, myGeneration: Int) {
        val context = appContext
        if (context == null) {
            failSession(myGeneration, "NOT_AVAILABLE", "The app context is not available.")
            return
        }
        try {
            current.checkRecognitionSupport(
                listenIntent(),
                context.mainExecutor,
                object : RecognitionSupportCallback {
                    override fun onSupportResult(support: RecognitionSupport) {
                        // Drop a late callback before touching selection state.
                        if (myGeneration != generation || !sessionActive) {
                            destroyRecognizer(current)
                            return
                        }
                        val installed = try {
                            support.installedOnDeviceLanguages
                        } catch (e: Exception) {
                            Log.e(TAG, "support languages: ${e.javaClass.simpleName}")
                            null
                        }
                        // Start the locale that is actually installed — accepting
                        // en-IN/en-GB here while starting an uninstalled en-US
                        // would fail the listen. Below API 33 there is no
                        // support query, so the en-US default stands.
                        val supported = try {
                            support.supportedOnDeviceLanguages
                        } catch (_: Exception) { null }
                        // A provider can report incomplete installed-model metadata.
                        // Only the on-device factory was used. Let that same local
                        // recognizer attempt supported English and report actual
                        // LANGUAGE_UNAVAILABLE if it cannot load the model.
                        val locale = selectRecognitionEnglish(installed, supported)
                        if (locale == null) {
                            failSession(
                                myGeneration,
                                "LANGUAGE_UNAVAILABLE",
                                "This on-device recognizer does not support English.",
                            )
                            return
                        }
                        beginListening(current, myGeneration, locale)
                    }

                    override fun onError(error: Int) {
                        Log.e(TAG, "support check error code=$error")
                        if (error == SpeechRecognizer.ERROR_CANNOT_CHECK_SUPPORT) {
                            // Unsupported metadata query is not permission to use
                            // a server recognizer: keep this same local instance.
                            beginListening(current, myGeneration, defaultEnglish())
                        } else {
                            failSession(myGeneration, "SUPPORT_CHECK_FAILED",
                                "On-device English support could not be verified.")
                        }
                    }
                },
            )
        } catch (e: Exception) {
            Log.e(TAG, "support check start: ${e.javaClass.simpleName}")
            failSession(
                myGeneration,
                "SUPPORT_CHECK_FAILED",
                "On-device English support could not be verified.",
            )
        }
    }

    private fun defaultEnglish(): String = LANGUAGE
    // The device's display locale (e.g. en-DE) is not necessarily a speech
    // model locale. Use installed/supported tags when reported, otherwise
    // request standard en-US from the same strictly on-device recognizer.

    private fun selectRecognitionEnglish(installed: List<String>?, supported: List<String>?): String? {
        selectInstalledEnglish(installed)?.let { return it }
        selectInstalledEnglish(supported)?.let { return it }
        // Explicit non-English support is different from missing metadata.
        if (!supported.isNullOrEmpty()) return null
        return defaultEnglish()
    }

    /// Picks the locale to actually start listening with: device-default
    /// English when installed, else en-US, else another installed English
    /// locale. Exact English only ("en" or "en-<REGION>" after underscore to
    /// BCP 47 hyphen normalization) — a bare startsWith("en") would also
    /// match non-English tags, so it is never used here. Null when nothing
    /// installed is English; the caller then fails closed.
    private fun selectInstalledEnglish(installed: List<String>?): String? {
        if (installed.isNullOrEmpty()) return null
        fun englishTag(tag: String): String? {
            val normalized = tag.replace('_', '-')
            if (normalized.equals("en", ignoreCase = true)) return normalized
            if (normalized.length > 3 &&
                normalized.substring(0, 3).equals("en-", ignoreCase = true)
            ) {
                return normalized
            }
            return null
        }
        val englishInstalled = installed.mapNotNull { englishTag(it) }
        if (englishInstalled.isEmpty()) return null
        val deviceTag = englishTag(Locale.getDefault().toLanguageTag())
        if (deviceTag != null) {
            val deviceInstalled = englishInstalled.firstOrNull {
                it.equals(deviceTag, ignoreCase = true)
            }
            if (deviceInstalled != null) return deviceInstalled
        }
        val usInstalled = englishInstalled.firstOrNull {
            it.equals("en-US", ignoreCase = true)
        }
        if (usInstalled != null) return usInstalled
        return englishInstalled.first()
    }

    private fun beginListening(
        current: SpeechRecognizer,
        myGeneration: Int,
        locale: String,
    ) {
        if (myGeneration != generation || !sessionActive) {
            destroyRecognizer(current)
            return
        }
        try {
            Log.i(TAG, "on-device recognition locale=$locale")
            current.startListening(listenIntent(locale))
        } catch (e: Exception) {
            Log.e(TAG, "startListening: ${e.javaClass.simpleName}")
            failSession(
                myGeneration,
                "START_FAILED",
                "Listening could not start on-device.",
            )
        }
    }

    private fun stopSession(reason: String?) {
        val sessionId = activeSessionId
        if (!sessionActive || sessionId == null) return
        generation++
        if (reason != null) {
            emit(mapOf("type" to "stopped", "sessionId" to sessionId, "reason" to reason))
        } else {
            emit(mapOf("type" to "stopped", "sessionId" to sessionId))
        }
        endSession()
    }

    private fun failSession(myGeneration: Int, code: String, reason: String) {
        // Read the session id only while this generation is still current:
        // no newer session can exist here, so it cannot be mis-tagged.
        if (myGeneration != generation || !sessionActive) return
        val sessionId = activeSessionId ?: return
        emit(mapOf("type" to "error", "sessionId" to sessionId, "code" to code, "reason" to reason))
        endSession()
    }

    private fun endSession() {
        sessionActive = false
        activeSessionId = null
        val current = recognizer
        recognizer = null
        destroyRecognizer(current)
    }

    private fun endSessionSilently() {
        generation++
        endSession()
    }

    private fun destroyRecognizer(current: SpeechRecognizer?) {
        if (current == null) return
        try {
            current.cancel()
        } catch (e: Exception) {
            Log.e(TAG, "recognizer cancel: ${e.javaClass.simpleName}")
        }
        try {
            current.destroy()
        } catch (e: Exception) {
            Log.e(TAG, "recognizer destroy: ${e.javaClass.simpleName}")
        }
    }

    private fun emit(event: Map<String, Any?>) {
        val sink = eventSink ?: return
        mainHandler.post {
            try {
                sink.success(event)
            } catch (e: Exception) {
                Log.e(TAG, "emit: ${e.javaClass.simpleName}")
            }
        }
    }

    // Nested (not inner): an inner class inside a singleton object is invalid,
    // so outer state is reached through the LocalVoiceBridge qualifier. The
    // owning session id is captured at construction and echoed in every
    // event, so a stale callback can never be tagged as a newer session.
    private class VoiceListener(private val owner: Int, private val session: Long) :
        RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            if (owner != LocalVoiceBridge.generation || !LocalVoiceBridge.sessionActive) return
            LocalVoiceBridge.emit(mapOf("type" to "ready", "sessionId" to session))
        }
        override fun onBeginningOfSpeech() = Unit
        override fun onRmsChanged(rmsdB: Float) = Unit
        override fun onBufferReceived(buffer: ByteArray?) = Unit
        override fun onEndOfSpeech() = Unit
        override fun onEvent(eventType: Int, params: Bundle?) = Unit

        override fun onPartialResults(partialResults: Bundle?) {
            if (owner != LocalVoiceBridge.generation || !LocalVoiceBridge.sessionActive) return
            val text = partialResults
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.trim()
                .orEmpty()
            if (text.isEmpty()) return
            LocalVoiceBridge.emit(
                mapOf("type" to "partial", "sessionId" to session, "text" to text),
            )
        }

        override fun onResults(results: Bundle?) {
            if (owner != LocalVoiceBridge.generation || !LocalVoiceBridge.sessionActive) return
            LocalVoiceBridge.generation++
            val text = results
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.trim()
                .orEmpty()
            if (text.isEmpty()) {
                LocalVoiceBridge.emit(
                    mapOf(
                        "type" to "error",
                        "sessionId" to session,
                        "code" to "NO_MATCH",
                        "reason" to "No speech was recognized on-device.",
                    ),
                )
            } else {
                LocalVoiceBridge.emit(
                    mapOf("type" to "final", "sessionId" to session, "text" to text),
                )
            }
            LocalVoiceBridge.endSession()
        }

        override fun onError(error: Int) {
            if (owner != LocalVoiceBridge.generation || !LocalVoiceBridge.sessionActive) return
            LocalVoiceBridge.generation++
            Log.e(TAG, "recognizer error code=$error")
            LocalVoiceBridge.emit(
                mapOf(
                    "type" to "error",
                    "sessionId" to session,
                    "code" to LocalVoiceBridge.errorName(error),
                    "reason" to LocalVoiceBridge.errorReason(error),
                ),
            )
            LocalVoiceBridge.endSession()
        }
    }

    private fun errorName(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_AUDIO -> "AUDIO"
        SpeechRecognizer.ERROR_CLIENT -> "CLIENT"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "PERMISSION_REQUIRED"
        SpeechRecognizer.ERROR_NETWORK -> "NETWORK"
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "NETWORK_TIMEOUT"
        SpeechRecognizer.ERROR_NO_MATCH -> "NO_MATCH"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "RECOGNIZER_BUSY"
        SpeechRecognizer.ERROR_SERVER -> "SERVER"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "SPEECH_TIMEOUT"
        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "LANGUAGE_UNAVAILABLE"
        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> "LANGUAGE_NOT_SUPPORTED"
        else -> "RECOGNITION_ERROR"
    }

    private fun errorReason(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_AUDIO -> "The microphone could not capture audio on-device."
        SpeechRecognizer.ERROR_CLIENT -> "The on-device recognizer client failed."
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
            "Microphone permission was not granted. Call requestPermission after an explicit user action."
        SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT ->
            "On-device recognition must not use the network; this error is reported without retry."
        SpeechRecognizer.ERROR_NO_MATCH -> "No speech was recognized on-device."
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "The on-device recognizer is busy."
        SpeechRecognizer.ERROR_SERVER -> "The on-device recognition service failed."
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech was heard before the timeout."
        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "The local English speech model is unavailable. Install an offline English speech pack in your device's speech settings."
        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> "This on-device recognizer does not support the requested English locale."
        else -> "On-device recognition failed without using the network."
    }
}
