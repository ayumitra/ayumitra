package app.ayumitra.ayumitra

import android.app.Activity
import android.app.DownloadManager
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Environment
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * Automatic on-device model setup bridge (Sub-owned file).
 *
 * Channels:
 * - MethodChannel `app.ayumitra/model_setup`: `ensure {role} -> Map`,
 *   `status {role} -> Map`. `role` is exactly `assistant` or `embedding`;
 *   anything else fails with BAD_ROLE. No URLs, paths, or tokens are
 *   accepted from Dart: both descriptors below are the only artifacts this
 *   bridge can ever fetch.
 *
 * Hard rules:
 * - Android DownloadManager only (OS-managed, resumable across background
 *   and process death). No inference, no AI network calls, no health data.
 * - READY requires exact byte size plus SHA-256, computed on a worker
 *   thread, never the GUI thread. The verified file is then copied with
 *   `File.copyTo` into the app-private `filesDir/ayumitra-models` dir.
 * - Present private assets are reused after one worker hash check per
 *   process; the cached verdict tracks size plus mtime, so a replaced file
 *   is never trusted. A corrupt or wrong-size file at the reserved private
 *   name self-repairs from `ensure` (delete only that exact bridge-known
 *   file, requeue the pinned asset); `status` only reports it and never
 *   mutates or enqueues.
 * - Finalization is atomic: the verified download is copied to a controlled
 *   `.verified.part` temp, size+hash re-verified, then renamed, so only a
 *   verified final ever exists at the reserved path. Crash leftovers under
 *   that temp name are cleaned at register and on `ensure`.
 * - Download destination is only the app's own external files dir with a
 *   role-specific cache name; download ids persist in private
 *   SharedPreferences so restarts resume without duplicates. Custom models
 *   and user data are never deleted: only this bridge's own download/cache
 *   files are removed, and only when corrupt.
 * - `status` never enqueues; only an explicit `ensure` starts or retries.
 * - Results are answered synchronously on the main thread and no
 *   Flutter result is ever retained. The worker is process-scoped on the
 *   application context with no engine coupling: one single-thread worker
 *   plus one lock serialize every prefs/cache mutation, the long hash and
 *   copy stay outside the UI lock, and only the short verified commit
 *   (rename, prefs, download record) runs under it. Logs carry roles,
 *   states, and byte counts only — never health strings, URLs, or prompts.
 */
object LocalModelSetupBridge {
    private const val CHANNEL = "app.ayumitra/model_setup"
    private const val TAG = "LocalModelSetupBridge"
    private const val PREFS = "ayumitra_model_setup"
    private const val ROLE_ASSISTANT = "assistant"
    private const val ROLE_EMBEDDING = "embedding"

    private data class Descriptor(
        val role: String,
        val fileName: String,
        val url: String,
        val bytes: Long,
        val sha256: String,
        val title: String,
    )

    // Immutable official artifacts only. Revisions are pinned, so these
    // URLs can never resolve to anything else.
    private val DESCRIPTORS = mapOf(
        ROLE_ASSISTANT to Descriptor(
            role = ROLE_ASSISTANT,
            fileName = "gemma-4-E2B-it.litertlm",
            url = "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm" +
                "/resolve/b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1" +
                "/gemma-4-E2B-it.litertlm",
            bytes = 2588147712L,
            sha256 = "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c",
            title = "Preparing Ayumitra local assistant",
        ),
        ROLE_EMBEDDING to Descriptor(
            role = ROLE_EMBEDDING,
            url = "https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm" +
                "/resolve/9be6e8b90982095dc05c2bd162e4b954ee4dbac7" +
                "/embeddinggemma-2-text-270m.litertlm",
            fileName = "embeddinggemma-2-text-270m.litertlm",
            bytes = 164626432L,
            sha256 = "2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb",
            title = "Preparing Ayumitra local search",
        ),
    )

    private var appContext: Context? = null
    private val lock = Any()
    private val verifying = mutableSetOf<String>()
    // Verified-ready fingerprint per role: size + mtime, so a replaced file
    // is never trusted on a stale verdict.
    private val verifiedReady = mutableMapOf<String, String>()
    private val lastFailure = mutableMapOf<String, String>()
    private val worker = Executors.newSingleThreadExecutor()

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        appContext = activity.applicationContext
        synchronized(lock) {
            // Crash-partial cleanup: bridge-known temp names only, and never
            // a temp a live worker may still commit.
            for (descriptor in DESCRIPTORS.values) {
                if (!verifying.contains(descriptor.role)) {
                    deleteOwnFile(partFile(descriptor))
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ensure" -> ensure(call, result)
                    "status" -> status(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun descriptorOrError(
        call: MethodCall,
        result: MethodChannel.Result,
    ): Descriptor? {
        val role = call.argument<String>("role")
        val descriptor = if (role != null) DESCRIPTORS[role] else null
        if (descriptor == null) {
            result.error(
                "BAD_ROLE",
                "role must be assistant or embedding.",
                null,
            )
            return null
        }
        return descriptor
    }

    private fun prefs() =
        appContext!!.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun downloadIdKey(role: String) = "download_id_$role"

    private fun privateFile(descriptor: Descriptor): File =
        File(File(appContext!!.filesDir, "ayumitra-models"), descriptor.fileName)

    // Controlled temp name for atomic finalization. Crash leftovers under
    // this exact name are the only files cleanup ever removes besides the
    // reserved final and download-cache names above.
    private fun partFile(descriptor: Descriptor): File =
        File(
            File(appContext!!.filesDir, "ayumitra-models"),
            "${descriptor.fileName}.verified.part",
        )

    private fun fingerprintOf(file: File) = "${file.length()}:${file.lastModified()}"

    private fun cacheFile(descriptor: Descriptor): File? {
        val base = appContext!!.getExternalFilesDir(
            Environment.DIRECTORY_DOWNLOADS,
        ) ?: return null
        return File(base, "ayumitra-models/${descriptor.fileName}.download")
    }

    private fun storedDownloadId(role: String): Long =
        prefs().getLong(downloadIdKey(role), -1L)

    private data class DownloadState(
        val status: Int?,
        val bytesSoFar: Long,
        val reason: Int?,
    )

    private fun queryDownload(id: Long): DownloadState? {
        val context = appContext ?: return null
        val manager = context.getSystemService(DownloadManager::class.java)
            ?: return null
        var cursor: Cursor? = null
        return try {
            cursor = manager.query(DownloadManager.Query().setFilterById(id))
            if (cursor == null || !cursor.moveToFirst()) return null
            val statusIndex = cursor.getColumnIndex(
                DownloadManager.COLUMN_STATUS,
            )
            val bytesIndex = cursor.getColumnIndex(
                DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR,
            )
            val reasonIndex = cursor.getColumnIndex(DownloadManager.COLUMN_REASON)
            DownloadState(
                status = if (statusIndex >= 0) cursor.getInt(statusIndex) else null,
                bytesSoFar = if (bytesIndex >= 0) cursor.getLong(bytesIndex) else 0L,
                reason = if (reasonIndex >= 0) cursor.getInt(reasonIndex) else null,
            )
        } catch (e: Exception) {
            Log.e(TAG, "download query: ${e.javaClass.simpleName}")
            null
        } finally {
            try {
                cursor?.close()
            } catch (e: Exception) {
                Log.e(TAG, "cursor close: ${e.javaClass.simpleName}")
            }
        }
    }

    private fun reply(
        result: MethodChannel.Result,
        descriptor: Descriptor,
        state: String,
        downloadedBytes: Long,
        path: String? = null,
        reason: String? = null,
    ) {
        val map = mutableMapOf<String, Any?>(
            "state" to state,
            "role" to descriptor.role,
            "downloadedBytes" to downloadedBytes,
            "totalBytes" to descriptor.bytes,
        )
        if (path != null) {
            map["path"] = path
            map["sha256"] = descriptor.sha256
        }
        if (reason != null) map["reason"] = reason
        result.success(map)
    }

    private fun pausedReason(reason: Int?): String = when (reason) {
        DownloadManager.PAUSED_WAITING_FOR_NETWORK,
        DownloadManager.PAUSED_QUEUED_FOR_WIFI,
        -> "PAUSED_NETWORK"
        else -> "PAUSED"
    }

    private fun downloadReason(reason: Int?): String = when (reason) {
        DownloadManager.ERROR_INSUFFICIENT_SPACE -> "NO_SPACE"
        DownloadManager.ERROR_CANNOT_RESUME,
        DownloadManager.ERROR_FILE_ERROR,
        DownloadManager.ERROR_FILE_ALREADY_EXISTS,
        -> "DOWNLOAD_FILE_ERROR"
        DownloadManager.ERROR_HTTP_DATA_ERROR,
        DownloadManager.ERROR_TOO_MANY_REDIRECTS,
        DownloadManager.ERROR_UNHANDLED_HTTP_CODE,
        -> "DOWNLOAD_NETWORK_ERROR"
        DownloadManager.ERROR_DEVICE_NOT_FOUND -> "DOWNLOAD_STORAGE_MISSING"
        else -> "DOWNLOAD_FAILED"
    }

    private fun ensure(call: MethodCall, result: MethodChannel.Result) {
        val descriptor = descriptorOrError(call, result) ?: return
        val context = appContext
        if (context == null) {
            result.error("NOT_AVAILABLE", "The app context is not available.", null)
            return
        }
        synchronized(lock) {
            if (verifying.contains(descriptor.role)) {
                reply(result, descriptor, "verifying", descriptor.bytes)
                return
            }
            // A crashed finalize leaves only the controlled .part temp; it
            // is never a valid asset, so drop it before any state verdict.
            deleteOwnFile(partFile(descriptor))
            val staged = privateFile(descriptor)
            if (staged.length() == descriptor.bytes) {
                if (verifiedReady[descriptor.role] == fingerprintOf(staged)) {
                    reply(
                        result,
                        descriptor,
                        "ready",
                        descriptor.bytes,
                        path = staged.absolutePath,
                    )
                    return
                }
                // Prefer the present private asset (including pre-staged
                // files) over any stale download record; it still needs its
                // one hash check before READY.
                val stale = storedDownloadId(descriptor.role)
                if (stale >= 0) removeDownloadLocked(descriptor, stale)
                if (lastFailure[descriptor.role] != null) {
                    // Reserved-path self-repair: this exact bridge-known
                    // filename failed verification, so delete only it and
                    // requeue the pinned asset. Anything under another name
                    // (custom models, user data) is never touched here.
                    deleteOwnFile(staged)
                    verifiedReady.remove(descriptor.role)
                    lastFailure.remove(descriptor.role)
                    enqueueFresh(result, descriptor)
                    return
                }
                beginVerify(descriptor, staged, null)
                reply(result, descriptor, "verifying", descriptor.bytes)
                return
            }
            verifiedReady.remove(descriptor.role)
            if (staged.exists()) {
                // Wrong-size reserved asset: bridge-known filename only.
                // status() reports this without touching it; ensure() repairs.
                deleteOwnFile(staged)
                val leftover = storedDownloadId(descriptor.role)
                if (leftover >= 0) removeDownloadLocked(descriptor, leftover)
            }
            val id = storedDownloadId(descriptor.role)
            if (id >= 0) {
                val current = queryDownload(id)
                when (current?.status) {
                    DownloadManager.STATUS_RUNNING -> {
                        reply(
                            result,
                            descriptor,
                            "downloading",
                            minOf(current?.bytesSoFar ?: 0L, descriptor.bytes),
                        )
                        return
                    }
                    DownloadManager.STATUS_PAUSED -> {
                        reply(
                            result,
                            descriptor,
                            "downloading",
                            minOf(current?.bytesSoFar ?: 0L, descriptor.bytes),
                            reason = pausedReason(current?.reason),
                        )
                        return
                    }
                    DownloadManager.STATUS_PENDING -> {
                        reply(result, descriptor, "queued", 0L)
                        return
                    }
                    DownloadManager.STATUS_SUCCESSFUL -> {
                        val cache = cacheFile(descriptor)
                        if (cache == null) {
                            reply(
                                result,
                                descriptor,
                                "failed",
                                0L,
                                reason = "DOWNLOAD_STORAGE_MISSING",
                            )
                            return
                        }
                        beginVerify(descriptor, cache, id)
                        reply(result, descriptor, "verifying", descriptor.bytes)
                        return
                    }
                    else -> {
                        // Failed or vanished: drop only our own record and
                        // fall through to a fresh explicit enqueue below.
                        removeDownloadLocked(descriptor, id)
                    }
                }
            }
            enqueueFresh(result, descriptor)
        }
    }

    // Fresh explicit enqueue shared by first setup and self-repair. The only
    // place a download is ever started; status() never calls it.
    private fun enqueueFresh(
        result: MethodChannel.Result,
        descriptor: Descriptor,
    ) {
        lastFailure.remove(descriptor.role)
        val freshId = enqueueLocked(descriptor)
        if (freshId == null) {
            reply(result, descriptor, "failed", 0L, reason = "ENQUEUE_FAILED")
        } else {
            reply(result, descriptor, "queued", 0L)
        }
    }

    private fun status(call: MethodCall, result: MethodChannel.Result) {
        val descriptor = descriptorOrError(call, result) ?: return
        if (appContext == null) {
            result.error("NOT_AVAILABLE", "The app context is not available.", null)
            return
        }
        synchronized(lock) {
            if (verifying.contains(descriptor.role)) {
                reply(result, descriptor, "verifying", descriptor.bytes)
                return
            }
            val staged = privateFile(descriptor)
            if (staged.length() == descriptor.bytes) {
                if (verifiedReady[descriptor.role] == fingerprintOf(staged)) {
                    reply(
                        result,
                        descriptor,
                        "ready",
                        descriptor.bytes,
                        path = staged.absolutePath,
                    )
                    return
                }
                val stagedFailure = lastFailure[descriptor.role]
                if (stagedFailure != null) {
                    // Known-corrupt reserved asset: reported only. ensure()
                    // performs the self-repair; status never mutates.
                    reply(
                        result,
                        descriptor,
                        "failed",
                        descriptor.bytes,
                        path = staged.absolutePath,
                        reason = stagedFailure,
                    )
                    return
                }
                // Size matches but bytes are unverified: report verifying and
                // start the worker check. Never report ready without a hash.
                beginVerify(descriptor, staged, null)
                reply(result, descriptor, "verifying", descriptor.bytes)
                return
            }
            verifiedReady.remove(descriptor.role)
            if (staged.exists()) {
                // Wrong-size reserved asset: reported only, never touched.
                // Bytes are clamped so they can never exceed the total.
                reply(
                    result,
                    descriptor,
                    "failed",
                    minOf(staged.length(), descriptor.bytes),
                    reason = "SIZE_MISMATCH",
                )
                return
            }
            val failure = lastFailure[descriptor.role]
            if (failure != null) {
                reply(result, descriptor, "failed", 0L, reason = failure)
                return
            }
            val id = storedDownloadId(descriptor.role)
            if (id < 0) {
                reply(result, descriptor, "failed", 0L, reason = "NOT_REQUESTED")
                return
            }
            val current = queryDownload(id)
            if (current == null) {
                reply(result, descriptor, "failed", 0L, reason = "DOWNLOAD_UNKNOWN")
                return
            }
            when (current.status) {
                DownloadManager.STATUS_RUNNING ->
                    reply(
                        result,
                        descriptor,
                        "downloading",
                        minOf(current.bytesSoFar, descriptor.bytes),
                    )
                DownloadManager.STATUS_PAUSED ->
                    reply(
                        result,
                        descriptor,
                        "downloading",
                        minOf(current.bytesSoFar, descriptor.bytes),
                        reason = pausedReason(current.reason),
                    )
                DownloadManager.STATUS_PENDING ->
                    reply(result, descriptor, "queued", 0L)
                DownloadManager.STATUS_SUCCESSFUL -> {
                    val cache = cacheFile(descriptor)
                    if (cache == null) {
                        reply(
                            result,
                            descriptor,
                            "failed",
                            0L,
                            reason = "DOWNLOAD_STORAGE_MISSING",
                        )
                    } else {
                        beginVerify(descriptor, cache, id)
                        reply(result, descriptor, "verifying", descriptor.bytes)
                    }
                }
                else -> reply(
                    result,
                    descriptor,
                    "failed",
                    0L,
                    reason = downloadReason(current.reason),
                )
            }
        }
    }

    private fun enqueueLocked(descriptor: Descriptor): Long? {
        val context = appContext ?: return null
        return try {
            val manager = context.getSystemService(DownloadManager::class.java)
                ?: return null
            val cache = cacheFile(descriptor) ?: return null
            cache.parentFile?.mkdirs()
            if (cache.exists()) cache.delete()
            val request =
                DownloadManager.Request(Uri.parse(descriptor.url)).apply {
                    setTitle(descriptor.title)
                    setDescription("Downloading on-device model over Wi-Fi")
                    setAllowedOverMetered(false)
                    setAllowedOverRoaming(false)
                    setNotificationVisibility(
                        DownloadManager.Request.VISIBILITY_VISIBLE,
                    )
                    setDestinationInExternalFilesDir(
                        context,
                        Environment.DIRECTORY_DOWNLOADS,
                        "ayumitra-models/${descriptor.fileName}.download",
                    )
                }
            val id = manager.enqueue(request)
            prefs().edit().putLong(downloadIdKey(descriptor.role), id).apply()
            Log.i(TAG, "enqueue role=${descriptor.role} bytes=${descriptor.bytes}")
            id
        } catch (e: Exception) {
            Log.e(TAG, "enqueue: ${e.javaClass.simpleName}")
            null
        }
    }

    private fun removeDownloadLocked(descriptor: Descriptor, id: Long) {
        try {
            appContext
                ?.getSystemService(DownloadManager::class.java)
                ?.remove(id)
        } catch (e: Exception) {
            Log.e(TAG, "download remove: ${e.javaClass.simpleName}")
        }
        prefs().edit().remove(downloadIdKey(descriptor.role)).apply()
    }

    private fun deleteOwnFile(file: File) {
        try {
            if (file.exists()) file.delete()
        } catch (e: Exception) {
            Log.e(TAG, "cache delete: ${e.javaClass.simpleName}")
        }
    }

    // Must be called with [lock] held. Starts worker verification of a fully
    // present file: the private staged asset, or the finished OS download
    // (committed into private storage only after size+hash pass).
    private fun beginVerify(descriptor: Descriptor, file: File, id: Long?) {
        if (!verifying.add(descriptor.role)) return
        worker.execute {
            // Off-lock phase: long hash (plus temp staging for downloads).
            // Nothing here touches prefs, the DownloadManager record, or
            // Flutter results; the commit below runs under the lock.
            var failure: String? = null
            try {
                val before = fingerprintOf(file)
                val matches = shaMatches(file, descriptor)
                if (before != fingerprintOf(file)) {
                    Log.e(
                        TAG,
                        "verify changed during hash role=${descriptor.role}",
                    )
                    failure = "VERIFY_ERROR"
                } else if (!matches) {
                    failure = if (file.length() == descriptor.bytes) {
                        "HASH_MISMATCH"
                    } else {
                        "SIZE_MISMATCH"
                    }
                } else if (id != null && !stagePart(descriptor, file)) {
                    failure = "COPY_ERROR"
                }
            } catch (e: Exception) {
                Log.e(TAG, "verify: ${e.javaClass.simpleName}")
                failure = "VERIFY_ERROR"
            }
            // Short commit phase under the lock: verified rename, prefs,
            // download record, and bookkeeping. No hash or copy happens here.
            synchronized(lock) {
                if (failure == null && id != null) {
                    failure = commitPart(descriptor, file, id)
                }
                verifying.remove(descriptor.role)
                if (failure != null) {
                    verifiedReady.remove(descriptor.role)
                    if (id != null) {
                        // Own download path only: temp, cache, and record. A
                        // staged private asset (id == null) is reported,
                        // never deleted; ensure() self-repairs it.
                        deleteOwnFile(partFile(descriptor))
                        deleteOwnFile(file)
                        removeDownloadLocked(descriptor, id)
                    }
                    lastFailure[descriptor.role] = failure
                    Log.e(TAG, "verify role=${descriptor.role} reason=$failure")
                } else {
                    lastFailure.remove(descriptor.role)
                    verifiedReady[descriptor.role] =
                        fingerprintOf(privateFile(descriptor))
                    Log.i(
                        TAG,
                        "ready role=${descriptor.role} bytes=${descriptor.bytes}",
                    )
                }
            }
        }
    }

    private fun shaMatches(file: File, descriptor: Descriptor): Boolean {
        if (!file.isFile || file.length() != descriptor.bytes) return false
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(262144)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        val actual = digest.digest().joinToString("") {
            ((it.toInt() and 0xFF).toString(16)).padStart(2, '0')
        }
        return actual.equals(descriptor.sha256, ignoreCase = true)
    }

    // Off-lock staging: copies a verified OS download to the controlled temp
    // and re-verifies it there. Mutates no prefs and no download record;
    // the locked commit below decides everything from the outcome.
    private fun stagePart(descriptor: Descriptor, source: File): Boolean {
        return try {
            privateFile(descriptor).parentFile?.mkdirs()
            val part = partFile(descriptor)
            if (part.exists()) part.delete()
            source.copyTo(part, overwrite = true)
            shaMatches(part, descriptor)
        } catch (e: Exception) {
            Log.e(TAG, "stage: ${e.javaClass.simpleName}")
            false
        }
    }

    // Short commit, called with [lock] held: renames the staged temp onto
    // the reserved final, then clears the OS record and the finished cache.
    // Returns a failure reason, or null when the private asset is in place.
    private fun commitPart(
        descriptor: Descriptor,
        source: File,
        id: Long,
    ): String? {
        val part = partFile(descriptor)
        if (!part.isFile || part.length() != descriptor.bytes) {
            return "COPY_ERROR"
        }
        val target = privateFile(descriptor)
        target.parentFile?.mkdirs()
        if (!part.renameTo(target)) {
            // Our bytes never landed; leave any pre-existing target alone.
            return "COPY_ERROR"
        }
        // The rename replaced the target with our verified bytes; a mismatch
        // here means the final is not verified, so drop it.
        if (!target.isFile || target.length() != descriptor.bytes) {
            deleteOwnFile(target)
            return "COPY_ERROR"
        }
        try {
            appContext
                ?.getSystemService(DownloadManager::class.java)
                ?.remove(id)
        } catch (e: Exception) {
            Log.e(TAG, "download remove: ${e.javaClass.simpleName}")
        }
        deleteOwnFile(source)
        prefs().edit().remove(downloadIdKey(descriptor.role)).apply()
        return null
    }
}
