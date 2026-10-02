package com.example.debloat

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * One-way native -> Dart event bus.
 *
 * The floating overlay runs outside the Flutter Activity, so it can't use the
 * MethodChannel directly. It pushes events (e.g. "connected") through this object,
 * which forwards them to whatever [EventChannel.EventSink] the Dart side registered.
 */
object AdbEvents {
    const val CHANNEL = "com.example.debloat/adb_events"

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    var sink: EventChannel.EventSink? = null

    /** Deliver [data] to the Dart listener on the platform main thread. */
    fun emit(data: Any?) {
        mainHandler.post { sink?.success(data) }
    }
}
