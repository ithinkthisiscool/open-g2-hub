package dev.g2hub.mobile

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// FlutterFragmentActivity: the Health Connect permission request (health plugin) uses
// registerForActivityResult, which needs a ComponentActivity.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        NotificationBridge.register(flutterEngine, applicationContext)
        DiagnosticsBridge.register(flutterEngine, this)
    }
}
