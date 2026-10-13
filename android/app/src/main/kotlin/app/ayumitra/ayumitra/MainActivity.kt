package app.ayumitra.ayumitra

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        LocalEmbeddingBridge.register(flutterEngine, this)
        LocalModelSetupBridge.register(flutterEngine, this)
        LocalProcessingBridge.register(flutterEngine, this)
        LocalVoiceBridge.register(flutterEngine, this)
    }
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        if (!LocalVoiceBridge.onRequestPermissionsResult(requestCode, permissions, grantResults)) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }
    override fun onPause() {
        super.onPause()
        // Foreground-only voice: release the mic when leaving the screen.
        LocalVoiceBridge.onHostPause()
    }
    override fun onDestroy() {
        LocalVoiceBridge.onHostDestroy()
        super.onDestroy()
    }
}
