package dev.g2hub.mobile

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Hands every posted phone notification to Dart (lib/services/notification_service.dart), which
 * filters it (allow/deny list, quiet hours, duplicates) and sends it to the glasses as the
 * official app's notification JSON file. Runs in the app process; when the Flutter engine is not
 * running, notifications are simply not forwarded.
 */
class G2NotificationListener : NotificationListenerService() {
    /**
     * Android unbinds notification listeners after an app update, a crash or under memory
     * pressure and does not always bind them again by itself: ask to be bound again (only works
     * while the user keeps notification access on; otherwise it is a no-op).
     */
    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                NotificationListenerService.requestRebind(ComponentName(this, G2NotificationListener::class.java))
            } catch (e: Exception) {
                // access was revoked: nothing to rebind
            }
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        val sink = NotificationBridge.sink ?: return
        val n = sbn.notification ?: return
        val extras = n.extras
        val pm = applicationContext.packageManager
        val label = try {
            pm.getApplicationLabel(pm.getApplicationInfo(sbn.packageName, 0)).toString()
        } catch (e: Exception) {
            sbn.packageName
        }
        val text = extras?.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
            ?: extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
        val map = hashMapOf<String, Any?>(
            "package" to sbn.packageName,
            "appName" to label,
            "title" to (extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""),
            "text" to text,
            "subText" to (extras?.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString() ?: ""),
            "ongoing" to (sbn.isOngoing || (n.flags and Notification.FLAG_FOREGROUND_SERVICE) != 0),
            "groupSummary" to ((n.flags and Notification.FLAG_GROUP_SUMMARY) != 0),
            "postTime" to sbn.postTime,
            "key" to sbn.key,
            "category" to (n.category ?: ""),
        )
        NotificationBridge.main.post { NotificationBridge.sink?.success(map) }
    }
}

object NotificationBridge {
    val main = Handler(Looper.getMainLooper())
    @Volatile var sink: EventChannel.EventSink? = null

    fun register(engine: FlutterEngine, context: Context) {
        EventChannel(engine.dartExecutor.binaryMessenger, "g2hub/notifications").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
                override fun onCancel(arguments: Any?) { sink = null }
            })
        MethodChannel(engine.dartExecutor.binaryMessenger, "g2hub/notifications/control").setMethodCallHandler { call, result ->
            when (call.method) {
                "isEnabled" -> {
                    val flat = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners") ?: ""
                    val me = ComponentName(context, G2NotificationListener::class.java).flattenToString()
                    result.success(flat.split(":").any { it == me })
                }
                "openSettings" -> {
                    val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                    result.success(true)
                }
                "listApps" -> {
                    val pm = context.packageManager
                    val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                    val infos = if (Build.VERSION.SDK_INT >= 33)
                        pm.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(0))
                    else @Suppress("DEPRECATION") pm.queryIntentActivities(intent, 0)
                    val apps = infos.map { mapOf("package" to it.activityInfo.packageName, "name" to it.loadLabel(pm).toString()) }
                        .distinctBy { it["package"] }.sortedBy { (it["name"] ?: "").lowercase() }
                    result.success(apps)
                }
                else -> result.notImplemented()
            }
        }
    }
}
