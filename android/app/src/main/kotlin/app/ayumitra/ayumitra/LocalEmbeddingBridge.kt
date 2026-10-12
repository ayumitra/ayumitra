package app.ayumitra.ayumitra

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.EmbeddingEngine
import com.google.ai.edge.litertlm.EmbeddingEngineConfig
import com.google.ai.edge.litertlm.InputData
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Local-only EmbeddingGemma 2 bridge (Sub-owned file).
 *
 * - Channel: `app.ayumitra/embeddings`
 * - Methods: `load {path}`, `embed {text} -> List<Double>`, `close`.
 * - Requires a local existing `.litertlm` file (manual import, no download).
 * - Serial background execution via a single-thread executor.
 * - No networking. Never logs input text or embedding values.
 *
 * SDK: `com.google.ai.edge.litertlm:litertlm-android:0.18.0` (pinned; add in
 * app/build.gradle.kts — Main-owned, Main adds it). API per
 * https://developers.google.com/edge/litert-lm/embedding_models (Kotlin tab):
 * `EmbeddingEngineConfig`, `EmbeddingEngine.initialize`,
 * `computeEmbedding(listOf(InputData.Text(text))).embedding`.
 *
 * Backend default is CPU (no manifest changes needed). To use GPU, Main can
 * switch to `Backend.GPU()` here AND add the `<uses-native-library>`
 * entries for libvndksupport/libOpenCL to AndroidManifest (Main-owned).
 */
object LocalEmbeddingBridge {
    private const val CHANNEL = "app.ayumitra/embeddings"
    private const val TAG = "LocalEmbeddingBridge"

    @Volatile
    private var engine: EmbeddingEngine? = null
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(flutterEngine: FlutterEngine, @Suppress("UNUSED_PARAMETER") context: Context) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "load" -> {
                        val path = call.argument<String>("path")
                        executor.execute {
                            try {
                                loadEngine(path)
                                replySuccess(result, true)
                            } catch (e: IllegalArgumentException) {
                                replyError(result, "BAD_PATH", e.message ?: "Invalid model path.")
                            } catch (e: Exception) {
                                Log.e(TAG, "load failed: ${e.javaClass.simpleName}")
                                replyError(result, "LOAD_FAILED", "Failed to load local model.")
                            }
                        }
                    }
                    "embed" -> {
                        val text = call.argument<String>("text")
                        executor.execute {
                            try {
                                val vector = embedText(text)
                                replySuccess(result, vector)
                            } catch (e: IllegalStateException) {
                                replyError(result, "NO_ENGINE", e.message ?: "Engine not loaded.")
                            } catch (e: IllegalArgumentException) {
                                replyError(result, "BAD_ARG", e.message ?: "Invalid text.")
                            } catch (e: Exception) {
                                Log.e(TAG, "embed failed: ${e.javaClass.simpleName}")
                                replyError(result, "EMBED_FAILED", "Embedding failed.")
                            }
                        }
                    }
                    "close" -> {
                        executor.execute {
                            try {
                                closeEngine()
                                replySuccess(result, true)
                            } catch (e: Exception) {
                                Log.e(TAG, "close failed: ${e.javaClass.simpleName}")
                                replyError(result, "CLOSE_FAILED", "Close failed.")
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Synchronized
    private fun loadEngine(path: String?) {
        require(!path.isNullOrBlank()) { "path must be a non-empty local file path." }
        val file = File(path)
        require(file.isFile && file.exists()) { "Model file does not exist: local import required." }
        require(path.endsWith(".litertlm", ignoreCase = true)) { "Model must be a local .litertlm file." }
        closeEngine()
        val config = EmbeddingEngineConfig(
            modelPath = file.absolutePath,
            backend = Backend.CPU(),
        )
        val created = EmbeddingEngine(config)
        created.initialize()
        engine = created
    }

    private fun embedText(text: String?): List<Double> {
        val current = engine ?: throw IllegalStateException("Call load with a local .litertlm path first.")
        val trimmed = text?.trim()
        require(!trimmed.isNullOrEmpty()) { "text must be non-empty." }
        require(trimmed.length <= 8000) { "text exceeds 8000-char limit." }
        val response = current.computeEmbedding(listOf(InputData.Text(trimmed)))
        return response.embedding.map { it.toDouble() }
    }

    @Synchronized
    private fun closeEngine() {
        try {
            engine?.close()
        } catch (e: Exception) {
            Log.e(TAG, "engine close: ${e.javaClass.simpleName}")
        } finally {
            engine = null
        }
    }

    private fun replySuccess(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun replyError(result: MethodChannel.Result, code: String, message: String) {
        mainHandler.post { result.error(code, message, null) }
    }
}
