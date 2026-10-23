package dev.g2hub.mobile

import android.app.Activity
import android.bluetooth.BluetoothManager
import android.content.ClipData
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException

/**
 * "Report a problem" (lib/services/diagnostics_platform.dart): phone / app / Bluetooth adapter
 * facts for the diagnostics bundle, and the Android share sheet for the finished file.
 * Nothing is sent anywhere by this code: the user picks the target in the share sheet.
 */
object DiagnosticsBridge {
    fun register(engine: FlutterEngine, activity: Activity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "g2hub/diagnostics").setMethodCallHandler { call, result ->
            when (call.method) {
                "deviceInfo" -> result.success(deviceInfo(activity))
                "share" -> {
                    val name = call.argument<String>("name") ?: ""
                    val subject = call.argument<String>("subject") ?: ""
                    result.success(share(activity, name, subject))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun deviceInfo(context: Context): Map<String, Any?> {
        val info = HashMap<String, Any?>()
        info["android_release"] = Build.VERSION.RELEASE
        info["android_sdk"] = Build.VERSION.SDK_INT
        info["manufacturer"] = Build.MANUFACTURER
        info["model"] = Build.MODEL
        info["device"] = Build.DEVICE
        info["supported_abis"] = Build.SUPPORTED_ABIS.joinToString(",")
        try {
            val pm = context.packageManager
            val pi = if (Build.VERSION.SDK_INT >= 33)
                pm.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
            else @Suppress("DEPRECATION") pm.getPackageInfo(context.packageName, 0)
            info["app_package"] = context.packageName
            info["app_version_name"] = pi.versionName
            info["app_version_code"] = if (Build.VERSION.SDK_INT >= 28) pi.longVersionCode else @Suppress("DEPRECATION") pi.versionCode.toLong()
            info["ble_supported"] = pm.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
        } catch (e: Exception) {
            // leave the app fields out
        }
        try {
            val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
            info["ble_adapter_present"] = adapter != null
            if (adapter != null) {
                info["ble_enabled"] = adapter.isEnabled
                info["ble_2m_phy"] = adapter.isLe2MPhySupported
                info["ble_coded_phy"] = adapter.isLeCodedPhySupported
                info["ble_extended_advertising"] = adapter.isLeExtendedAdvertisingSupported
                info["ble_max_advertising_data"] = adapter.leMaximumAdvertisingDataLength
                info["ble_offloaded_filtering"] = adapter.isOffloadedFilteringSupported
            }
        } catch (e: Exception) {
            // SecurityException on some OEM builds without the Bluetooth permission
            info["ble_error"] = e.javaClass.simpleName
        }
        return info
    }

    private fun share(activity: Activity, name: String, subject: String): Boolean {
        val file = DiagnosticsFileProvider.fileFor(activity, name) ?: return false
        val uri = DiagnosticsFileProvider.uriFor(activity, file.name)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "application/json"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, subject)
            clipData = ClipData.newRawUri(file.name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return try {
            activity.startActivity(Intent.createChooser(send, subject))
            true
        } catch (e: Exception) {
            false
        }
    }
}

/**
 * Read-only provider for the one report file in cache/diagnostics (not exported; access only
 * through the URI permission granted to the app the user shares with).
 */
class DiagnosticsFileProvider : ContentProvider() {
    companion object {
        fun authority(context: Context) = "${context.packageName}.diagnostics"

        fun uriFor(context: Context, name: String): Uri = Uri.Builder().scheme("content").authority(authority(context)).appendPath(name).build()

        /** The report file called [name], only directly inside cache/diagnostics. */
        fun fileFor(context: Context, name: String?): File? {
            if (name.isNullOrEmpty() || name.contains('/') || name.contains('\\') || name.startsWith(".")) return null
            val dir = File(context.cacheDir, "diagnostics").canonicalFile
            val f = File(dir, name).canonicalFile
            return if (f.parentFile == dir && f.isFile) f else null
        }
    }

    override fun onCreate(): Boolean = true

    private fun file(uri: Uri): File? = context?.let { fileFor(it, uri.lastPathSegment) }

    override fun getType(uri: Uri): String = "application/json"

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? {
        val f = file(uri) ?: return null
        val cols = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val row = arrayOfNulls<Any>(cols.size)
        cols.forEachIndexed { i, c ->
            row[i] = when (c) {
                OpenableColumns.DISPLAY_NAME -> f.name
                OpenableColumns.SIZE -> f.length()
                else -> null
            }
        }
        return MatrixCursor(cols, 1).apply { addRow(row) }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("read only")
        val f = file(uri) ?: throw FileNotFoundException(uri.toString())
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException("read only")
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}
