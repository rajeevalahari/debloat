package com.example.debloat

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.conscrypt.Conscrypt
import java.security.Security
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * Bridges the Flutter UI to the on-device ADB loopback.
 *
 * Channel: `com.example.debloat/adb`
 * Methods: pair(port, code), connect(port), getSystemApps(), uninstallApp(packageName),
 *          plus isConnected() / disconnect() helpers.
 */
class MainActivity : FlutterActivity() {

    private val channelName = "com.example.debloat/adb"
    private val host = "127.0.0.1"

    // ADB network I/O must never touch the UI thread.
    private val executor = Executors.newSingleThreadExecutor()
    // Separate pool for shell reads so a stream that never sends EOF can be timed out.
    private val readExecutor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // adbd's TLS handshake needs a TLS 1.3 capable provider; Conscrypt guarantees it.
        try {
            if (Security.getProvider("Conscrypt") == null) {
                Security.insertProviderAt(Conscrypt.newProvider(), 1)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Could not install Conscrypt provider: ${e.message}")
        }

        // Native -> Dart event stream (used by the floating window to report "connected").
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, AdbEvents.CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    AdbEvents.sink = events
                }

                override fun onCancel(arguments: Any?) {
                    AdbEvents.sink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pair" -> {
                        val port = call.argument<Int>("port")
                        val code = call.argument<String>("code")
                        if (port == null || code == null) {
                            result.error("ARGS", "port and code are required", null)
                        } else {
                            runInBackground(result) { pair(port, code) }
                        }
                    }

                    "connect" -> {
                        val port = call.argument<Int>("port")
                        if (port == null) {
                            result.error("ARGS", "port is required", null)
                        } else {
                            runInBackground(result) { connect(port) }
                        }
                    }

                    "connectAuto" -> runInBackground(result) { connectAuto() }

                    "isPaired" -> result.success(isPaired())

                    "hasOverlayPermission" ->
                        result.success(Settings.canDrawOverlays(this))

                    "requestOverlayPermission" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName"),
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                        result.success(null)
                    }

                    "openDeveloperOptions" -> {
                        val opened = runCatching {
                            startActivity(
                                Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                            )
                        }.isSuccess
                        if (!opened) {
                            runCatching {
                                startActivity(
                                    Intent(Settings.ACTION_SETTINGS)
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                                )
                            }
                        }
                        result.success(opened)
                    }

                    "showFloatingWindow" -> {
                        if (!Settings.canDrawOverlays(this)) {
                            result.error("NO_OVERLAY", "Overlay permission not granted", null)
                        } else {
                            FloatingWindowController.show(applicationContext)
                            result.success(true)
                        }
                    }

                    "hideFloatingWindow" -> {
                        FloatingWindowController.hide()
                        result.success(true)
                    }

                    "getSystemApps" -> runInBackground(result) { getSystemApps() }

                    "uninstallApp" -> {
                        val pkg = call.argument<String>("packageName")
                        if (pkg == null) {
                            result.error("ARGS", "packageName is required", null)
                        } else {
                            runInBackground(result) { uninstallApp(pkg) }
                        }
                    }

                    "isConnected" -> runInBackground(result) {
                        AdbConnectionManager.getInstance(applicationContext).isConnected
                    }

                    "disconnect" -> runInBackground(result) {
                        AdbConnectionManager.getInstance(applicationContext).disconnect()
                        true
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /** Runs [block] off the UI thread and posts success/error back on the UI thread. */
    private fun runInBackground(result: MethodChannel.Result, block: () -> Any?) {
        executor.execute {
            val outcome = runCatching(block)
            mainHandler.post {
                outcome
                    .onSuccess { result.success(it) }
                    .onFailure { e ->
                        Log.e(TAG, "ADB op failed", e)
                        result.error(
                            "ADB_ERROR",
                            e.message ?: e.toString(),
                            Log.getStackTraceString(e),
                        )
                    }
            }
        }
    }

    /** Pair with the local daemon using the Wireless Debugging pairing port + 6-digit code. */
    private fun pair(port: Int, code: String): Boolean =
        AdbConnectionManager.getInstance(applicationContext).pair(host, port, code)
            .also { if (it) markPaired() }

    /** Connect to the local daemon's Wireless Debugging connection port. */
    private fun connect(port: Int): Boolean =
        AdbConnectionManager.getInstance(applicationContext).connect(host, port)
            .also { if (it) markPaired() }

    /** Connect after auto-discovering the connection port via mDNS (pairing must precede). */
    private fun connectAuto(): Boolean =
        AdbConnectionManager.getInstance(applicationContext)
            .autoConnect(applicationContext, 25_000L)
            .also { if (it) markPaired() }

    /** Whether the user has successfully paired/connected on this device before. */
    private fun isPaired(): Boolean =
        getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(KEY_PAIRED, false)

    private fun markPaired() {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putBoolean(KEY_PAIRED, true).apply()
    }

    /**
     * Enumerate installed *system* apps in-process via [PackageManager].
     * Requires the QUERY_ALL_PACKAGES permission. Returns the data the UI needs:
     * package name, human label, and whether it is currently enabled.
     */
    private fun getSystemApps(): List<Map<String, Any>> {
        val pm = packageManager
        val self = packageName
        return pm.getInstalledApplications(PackageManager.GET_META_DATA)
            .asSequence()
            .filter { (it.flags and ApplicationInfo.FLAG_SYSTEM) != 0 }
            .filter { it.packageName != self }
            .map { info ->
                mapOf(
                    "packageName" to info.packageName,
                    "appName" to pm.getApplicationLabel(info).toString(),
                    "enabled" to info.enabled,
                )
            }
            .sortedBy { (it["appName"] as String).lowercase() }
            .toList()
    }

    /**
     * Runs `pm uninstall -k --user 0 <pkg>` over the ADB shell stream.
     *
     * Some devices/ROMs don't deliver a clean EOF on the shell stream, so a plain
     * blocking read can hang forever. We therefore read with a timeout AND verify the
     * real outcome via PackageManager (the package disappears for user 0 on success),
     * which is the ground truth regardless of what the stdout stream did.
     *
     * Returns "Success" or a "Failure ..." string for the Dart side to interpret.
     */
    private fun uninstallApp(packageName: String): String {
        val manager = AdbConnectionManager.getInstance(applicationContext)
        val output = runShellCommand("pm uninstall -k --user 0 $packageName", 8_000L)

        val succeeded = output.contains("Success", ignoreCase = true) ||
            !isPackageInstalled(packageName)
        return if (succeeded) "Success" else output.ifBlank { "Failure (no response)" }
    }

    /** Opens a shell stream for [command] and reads its output, capped at [timeoutMs]. */
    private fun runShellCommand(command: String, timeoutMs: Long): String {
        val manager = AdbConnectionManager.getInstance(applicationContext)
        val stream = manager.openStream("shell:$command")
        val reader = readExecutor.submit<String> {
            // Read line by line and stop at the result line, so we don't block waiting
            // for an EOF that some ROMs never send on a one-shot shell stream.
            val bufferedReader = stream.openInputStream().bufferedReader()
            val builder = StringBuilder()
            while (true) {
                val line = bufferedReader.readLine() ?: break
                builder.appendLine(line)
                if (line.contains("Success", ignoreCase = true) ||
                    line.contains("Failure", ignoreCase = true)
                ) {
                    break
                }
            }
            builder.toString().trim()
        }
        return try {
            reader.get(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (e: TimeoutException) {
            "" // No clean EOF; caller falls back to a PackageManager check.
        } catch (e: Exception) {
            ""
        } finally {
            reader.cancel(true)
            runCatching { stream.close() } // unblocks any read still pending
        }
    }

    /** True if [pkg] is still installed for the current user. */
    private fun isPackageInstalled(pkg: String): Boolean = try {
        packageManager.getApplicationInfo(pkg, 0)
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    companion object {
        private const val TAG = "Debloat"
        const val PREFS = "debloat_prefs"
        const val KEY_PAIRED = "paired"
    }
}
