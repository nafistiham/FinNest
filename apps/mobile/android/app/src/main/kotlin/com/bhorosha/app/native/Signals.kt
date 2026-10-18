package com.bhorosha.app.native

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.telephony.PhoneStateListener
import android.telephony.SubscriptionManager
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.view.WindowManager
import android.view.accessibility.AccessibilityManager
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.security.MessageDigest
import java.time.Instant
import java.util.concurrent.Executor

/**
 * Device signals for `/v1/risk/signals` and the EventChannel feed.
 *
 * Thread model: listeners deliver on the main looper (via [mainHandler]); the
 * snapshot may be built on the plugin executor. All latched state is
 * `@Volatile` and the snapshot only reads it.
 */
class Signals(
    private val context: Context,
    private val mainHandler: Handler,
) {
    companion object {
        const val PREFS = "bhorosha_native"
        private const val KEY_SIM_HASH = "sim_hash"
        private const val KEY_SIM_CHANGED_AT = "sim_changed_at"
        private const val CAPTURE_READS = 2
    }

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val mainExecutor: Executor = Executor { r -> mainHandler.post(r) }

    @Volatile private var sink: EventChannel.EventSink? = null
    @Volatile private var activity: Activity? = null

    @Volatile private var callState: String = "IDLE"
    @Volatile private var captureReadsLeft = 0
    @Volatile private var screenRecording = false
    @Volatile private var obscuredTouch = false

    // Listener handles so they can be unregistered.
    private var telephonyCallback: Any? = null
    @Suppress("DEPRECATION")
    private var phoneStateListener: PhoneStateListener? = null
    private var screenCaptureCallback: Any? = null
    private var screenRecordingCallback: Any? = null
    private var subscriptionsListener: SubscriptionManager.OnSubscriptionsChangedListener? = null

    // ---------------------------------------------------------------- lifecycle

    fun attach(activity: Activity) {
        this.activity = activity
        registerTelephony()
        registerSubscriptions()
        registerScreenCapture(activity)
        registerScreenRecording(activity)
    }

    fun detach() {
        val a = activity
        unregisterTelephony()
        unregisterSubscriptions()
        if (a != null) {
            unregisterScreenCapture(a)
            unregisterScreenRecording(a)
        }
        activity = null
    }

    fun setSink(sink: EventChannel.EventSink?) {
        this.sink = sink
    }

    /** Called after READ_PHONE_STATE was granted so the telephony callback can start. */
    fun onPhoneStatePermissionChanged() {
        unregisterTelephony()
        registerTelephony()
        recordSubscription()
    }

    /** Called by MainActivity (through the plugin) when an obscured touch was dropped. */
    fun onObscuredTouch() {
        obscuredTouch = true
        emit(mapOf("type" to "obscured_touch"))
    }

    // ---------------------------------------------------------------- snapshot

    /** Builds the `signals` + `device` payload. May run off the main thread. */
    fun snapshot(): Map<String, Any?> {
        val subscription = recordSubscription()
        val now = System.currentTimeMillis()
        val changedAt = subscription.changedAtMillis
        val changedHours: Double? =
            if (changedAt > 0L) (now - changedAt).toDouble() / 3_600_000.0 else null

        val capture = captureReadsLeft > 0
        if (capture) captureReadsLeft -= 1
        val obscured = obscuredTouch
        obscuredTouch = false

        val signals = mapOf<String, Any?>(
            "call_state" to callState,
            "audio_mode" to audioModeName(),
            "subscription_changed_hours" to changedHours,
            "accessibility_services" to enabledAccessibilityPackages(context),
            "screen_capture" to capture,
            "screen_recording" to screenRecording,
            "obscured_touch" to obscured,
        )
        val device = mapOf<String, Any?>(
            "model" to "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
            "os" to "Android ${Build.VERSION.RELEASE}",
            "rooted" to isRooted(),
            "sim_serial_hash" to subscription.hash,
            "sim_changed_at" to (if (changedAt > 0L) Instant.ofEpochMilli(changedAt).toString() else null),
        )
        return mapOf("signals" to signals, "device" to device)
    }

    private fun audioModeName(): String {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return ""
        return when (am.mode) {
            AudioManager.MODE_NORMAL -> "MODE_NORMAL"
            AudioManager.MODE_RINGTONE -> "MODE_RINGTONE"
            AudioManager.MODE_IN_CALL -> "MODE_IN_CALL"
            AudioManager.MODE_IN_COMMUNICATION -> "MODE_IN_COMMUNICATION"
            else -> "MODE_${am.mode}"
        }
    }

    // ---------------------------------------------------------------- SIM / subscription

    private data class Subscription(val hash: String, val changedAtMillis: Long)

    private fun hasPhoneState(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * sha256(subscriptionId + ":" + carrierId) of the default data subscription.
     * Stored on first sight; a different value later records a change epoch.
     */
    private fun recordSubscription(): Subscription {
        val current = currentSubscriptionHash()
        val stored = prefs.getString(KEY_SIM_HASH, "") ?: ""
        var changedAt = prefs.getLong(KEY_SIM_CHANGED_AT, 0L)
        if (current.isNotEmpty()) {
            if (stored.isEmpty()) {
                prefs.edit().putString(KEY_SIM_HASH, current).apply()
            } else if (stored != current) {
                changedAt = System.currentTimeMillis()
                prefs.edit()
                    .putString(KEY_SIM_HASH, current)
                    .putLong(KEY_SIM_CHANGED_AT, changedAt)
                    .apply()
            }
        }
        return Subscription(current, changedAt)
    }

    private fun currentSubscriptionHash(): String {
        if (!hasPhoneState()) return ""
        return try {
            val subId = SubscriptionManager.getDefaultDataSubscriptionId()
            if (subId == SubscriptionManager.INVALID_SUBSCRIPTION_ID) return ""
            val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
                ?: return ""
            val carrierId = tm.createForSubscriptionId(subId).simCarrierId
            sha256("$subId:$carrierId")
        } catch (_: Throwable) {
            ""
        }
    }

    private fun registerSubscriptions() {
        if (!hasPhoneState()) return
        val sm = context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE)
            as? SubscriptionManager ?: return
        val listener = object : SubscriptionManager.OnSubscriptionsChangedListener() {
            override fun onSubscriptionsChanged() {
                recordSubscription()
            }
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                sm.addOnSubscriptionsChangedListener(mainExecutor, listener)
            } else {
                @Suppress("DEPRECATION")
                sm.addOnSubscriptionsChangedListener(listener)
            }
            subscriptionsListener = listener
        } catch (_: Throwable) {
        }
    }

    private fun unregisterSubscriptions() {
        val l = subscriptionsListener ?: return
        subscriptionsListener = null
        try {
            val sm = context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE)
                as? SubscriptionManager
            sm?.removeOnSubscriptionsChangedListener(l)
        } catch (_: Throwable) {
        }
    }

    // ---------------------------------------------------------------- call state

    private fun registerTelephony() {
        if (!hasPhoneState()) {
            callState = "IDLE"
            return
        }
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                registerTelephonyCallback(tm)
            } else {
                @Suppress("DEPRECATION")
                val listener = object : PhoneStateListener() {
                    @Deprecated("Deprecated in Java")
                    override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                        updateCallState(state)
                    }
                }
                @Suppress("DEPRECATION")
                tm.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
                phoneStateListener = listener
            }
            @Suppress("DEPRECATION")
            updateCallState(tm.callState, emitEvent = false)
        } catch (_: Throwable) {
            callState = "IDLE"
        }
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private fun registerTelephonyCallback(tm: TelephonyManager) {
        val cb = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
            override fun onCallStateChanged(state: Int) {
                updateCallState(state)
            }
        }
        tm.registerTelephonyCallback(mainExecutor, cb)
        telephonyCallback = cb
    }

    private fun unregisterTelephony() {
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        try {
            val cb = telephonyCallback
            if (cb != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                tm?.unregisterTelephonyCallback(cb as TelephonyCallback)
            }
            val legacy = phoneStateListener
            if (legacy != null) {
                @Suppress("DEPRECATION")
                tm?.listen(legacy, PhoneStateListener.LISTEN_NONE)
            }
        } catch (_: Throwable) {
        }
        telephonyCallback = null
        phoneStateListener = null
    }

    private fun updateCallState(state: Int, emitEvent: Boolean = true) {
        val name = when (state) {
            TelephonyManager.CALL_STATE_RINGING -> "RINGING"
            TelephonyManager.CALL_STATE_OFFHOOK -> "OFFHOOK"
            else -> "IDLE"
        }
        val changed = name != callState
        callState = name
        if (emitEvent && changed) emit(mapOf("type" to "call_state", "value" to name))
    }

    // ---------------------------------------------------------------- screen capture / recording

    private fun registerScreenCapture(activity: Activity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
        try {
            val cb = Activity.ScreenCaptureCallback {
                captureReadsLeft = CAPTURE_READS
                emit(mapOf("type" to "screen_capture", "value" to true))
            }
            activity.registerScreenCaptureCallback(mainExecutor, cb)
            screenCaptureCallback = cb
        } catch (_: Throwable) {
        }
    }

    private fun unregisterScreenCapture(activity: Activity) {
        val cb = screenCaptureCallback ?: return
        screenCaptureCallback = null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
        try {
            activity.unregisterScreenCaptureCallback(cb as Activity.ScreenCaptureCallback)
        } catch (_: Throwable) {
        }
    }

    private fun registerScreenRecording(activity: Activity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) return
        try {
            val wm = activity.getSystemService(Context.WINDOW_SERVICE) as? WindowManager ?: return
            val cb = java.util.function.Consumer<Int> { state ->
                val active = state == WindowManager.SCREEN_RECORDING_STATE_VISIBLE
                val changed = active != screenRecording
                screenRecording = active
                if (changed) emit(mapOf("type" to "screen_recording", "value" to active))
            }
            val initial = wm.addScreenRecordingCallback(mainExecutor, cb)
            screenRecording = initial == WindowManager.SCREEN_RECORDING_STATE_VISIBLE
            screenRecordingCallback = cb
        } catch (_: Throwable) {
        }
    }

    private fun unregisterScreenRecording(activity: Activity) {
        val cb = screenRecordingCallback ?: return
        screenRecordingCallback = null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) return
        try {
            val wm = activity.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
            @Suppress("UNCHECKED_CAST")
            wm?.removeScreenRecordingCallback(cb as java.util.function.Consumer<Int>)
        } catch (_: Throwable) {
        }
        screenRecording = false
    }

    // ---------------------------------------------------------------- events

    private fun emit(event: Map<String, Any?>) {
        mainHandler.post {
            try {
                sink?.success(event)
            } catch (_: Throwable) {
            }
        }
    }
}

// -------------------------------------------------------------------- shared helpers

internal fun sha256(text: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
    return digest.joinToString("") { "%02x".format(it) }
}

/** `test-keys` build tag or an `su` binary on a well-known path. */
internal fun isRooted(): Boolean {
    if (Build.TAGS?.contains("test-keys") == true) return true
    val paths = listOf(
        "/system/bin/su", "/system/xbin/su", "/sbin/su", "/su/bin/su",
        "/system/sd/xbin/su", "/system/bin/failsafe/su", "/data/local/su",
        "/data/local/bin/su", "/data/local/xbin/su",
    )
    return try {
        paths.any { File(it).exists() }
    } catch (_: Throwable) {
        false
    }
}

/** Package names of enabled accessibility services (FEEDBACK_ALL_MASK). */
internal fun enabledAccessibilityPackages(context: Context): List<String> {
    return try {
        val am = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
            ?: return emptyList()
        am.getEnabledAccessibilityServiceList(
            android.accessibilityservice.AccessibilityServiceInfo.FEEDBACK_ALL_MASK,
        )
            .mapNotNull { it.resolveInfo?.serviceInfo?.packageName }
            .distinct()
    } catch (_: Throwable) {
        emptyList()
    }
}
