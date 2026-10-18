package com.bhorosha.app.native

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.bhorosha.app.MainActivity
import com.bhorosha.appsafety.AppSafetyCollector
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The `bhorosha_native` channel.
 *
 * Methods: getSignals, getAppSafetyBundle, prepareIntegrity, getIntegrityToken,
 * setSecure, openAppDetails, openAccessibilitySettings, uninstallApp,
 * openSettingsPanel, playPcm, stopPcm, requestPhoneStatePermission,
 * enterVoiceSession, exitVoiceSession.
 * Events on `bhorosha_native/events`: call_state, screen_capture,
 * screen_recording, obscured_touch, pcm_drained.
 *
 * `getAppSafetyBundle` replies with the App Safety collector's JSON **string**
 * (`AppSafetyRequest` body, `integrity_token` null). The same handler also
 * serves the channel `bhorosha/appsafety` as a compatibility alias.
 * `getAppSafetyAttestation` adds the canonical `bundle_hash` and, when a Play
 * Integrity provider is prepared, a fresh token bound to that hash.
 *
 * Heavy work runs on background executors: `getSignals` has its own, so a slow
 * app-safety scan (PackageManager over every installed app) never delays the
 * signals the PIN flow waits 1.5 s for. Every
 * [MethodChannel.Result] is answered on the main looper. Nothing throws across
 * the channel.
 *
 * FLAG_SECURE is sticky: the last `setSecure` request is remembered and
 * re-applied whenever an activity (re)attaches, and a call without an `on`
 * argument, or with no activity to apply it to, is an error, never a silent
 * "off".
 */
class BhoroshaNativePlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.RequestPermissionsResultListener {

    companion object {
        const val METHOD_CHANNEL = "bhorosha_native"
        const val EVENT_CHANNEL = "bhorosha_native/events"

        /** Alias (`bhorosha/appsafety`, method `getAppSafetyBundle`). */
        const val APPSAFETY_CHANNEL = AppSafetyCollector.CHANNEL
        private const val PHONE_STATE_REQUEST = 0x4248 // "BH"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService =
        Executors.newSingleThreadExecutor { r -> Thread(r, "bhorosha-native") }

    /** Signals only: never queued behind an app-safety scan. */
    private val signalsExecutor: ExecutorService =
        Executors.newSingleThreadExecutor { r -> Thread(r, "bhorosha-signals") }

    /** Last FLAG_SECURE request from Dart; re-applied on every attach. */
    @Volatile
    private var secureRequested = false

    private var methodChannel: MethodChannel? = null
    private var appSafetyChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var activity: Activity? = null

    private lateinit var appContext: Context
    private lateinit var signals: Signals
    private lateinit var appSafety: AppSafety
    private lateinit var integrity: Integrity
    private val pcm = PcmPlayer(
        callbackHandler = mainHandler,
        inVoiceSession = { voiceSession?.ownsMode() == true },
        onDrained = { emitEvent(mapOf("type" to "pcm_drained")) },
    )
    private var voiceSession: VoiceAudioSession? = null

    /** The same sink [Signals] uses; the plugin's own events (pcm_drained) go here. */
    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    private val pendingPermissionResults = ArrayList<MainThreadResult>()

    // ---------------------------------------------------------------- FlutterPlugin

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        signals = Signals(appContext, mainHandler)
        appSafety = AppSafety(appContext)
        integrity = Integrity(appContext)
        voiceSession = VoiceAudioSession(appContext)
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        appSafetyChannel = MethodChannel(binding.binaryMessenger, APPSAFETY_CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                if (call.method == AppSafetyCollector.METHOD) {
                    onMethodCall(MethodCall("getAppSafetyBundle", null), result)
                } else {
                    result.notImplemented()
                }
            }
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        appSafetyChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        appSafetyChannel = null
        eventChannel = null
        signals.setSink(null)
        eventSink = null
        voiceSession?.exit()
        voiceSession?.setActivity(null)
        pcm.dispose()
        executor.shutdown()
        signalsExecutor.shutdown()
    }

    // ---------------------------------------------------------------- ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
        (binding.activity as? MainActivity)?.onObscuredTouch = { signals.onObscuredTouch() }
        signals.attach(binding.activity)
        voiceSession?.setActivity(binding.activity)
        // A config change or re-attach builds a new window: re-apply the last
        // request so a protected screen never loses FLAG_SECURE silently.
        if (secureRequested) applySecure(binding.activity, true)
    }

    /** A config change keeps the voice session; the new activity takes it over. */
    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        // The activity is gone for good: never leave the phone in call mode.
        voiceSession?.exit()
        detachActivity()
    }

    private fun detachActivity() {
        voiceSession?.setActivity(null)
        signals.detach()
        (activity as? MainActivity)?.onObscuredTouch = null
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
        failPendingPermissions()
    }

    // ---------------------------------------------------------------- EventChannel

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        signals.setSink(events)
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        signals.setSink(null)
    }

    /** Same format and thread as [Signals]' events: a map, sent on the main looper. */
    private fun emitEvent(event: Map<String, Any?>) {
        mainHandler.post {
            try {
                eventSink?.success(event)
            } catch (_: Throwable) {
            }
        }
    }

    // ---------------------------------------------------------------- MethodChannel

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val safe = MainThreadResult(result, mainHandler)
        try {
            when (call.method) {
                "getSignals" -> background(safe, signalsExecutor) { signals.snapshot() }
                "getAppSafetyBundle" -> background(safe) { appSafety.bundleJson() }
                "getAppSafetyAttestation" -> attestation(safe)
                "prepareIntegrity" -> {
                    val number = call.argument<Any?>("cloudProjectNumber")?.toString()?.trim()
                    val parsed = number?.toLongOrNull()
                    if (parsed != null && parsed > 0L) integrity.prepare(parsed)
                    safe.success(null)
                }
                "getIntegrityToken" -> {
                    val hash = call.argument<String>("requestHash") ?: ""
                    if (hash.isEmpty()) {
                        safe.success(null)
                    } else {
                        integrity.token(hash) { token -> safe.success(token) }
                    }
                }
                "setSecure" -> {
                    val on = call.argument<Boolean>("on")
                    if (on == null) {
                        // Missing argument: an error, never treated as "off".
                        safe.error("bad_args", "on missing", null)
                    } else {
                        secureRequested = on
                        if (setSecure(on)) {
                            safe.success(null)
                        } else {
                            // Remembered and applied on the next attach; say so.
                            safe.error("no_activity", "no window to apply FLAG_SECURE to", null)
                        }
                    }
                }
                "openAppDetails" -> {
                    val pkg = call.argument<String>("package") ?: ""
                    if (pkg.isEmpty()) {
                        safe.error("bad_args", "package missing", null)
                    } else {
                        // The user may uninstall from the Settings page; the next check must
                        // see a fresh bundle, not the 60 s cache.
                        appSafety.invalidate()
                        openAppDetails(pkg)
                        safe.success(null)
                    }
                }
                "openAccessibilitySettings" -> {
                    // The user may turn a service off: the next check needs a fresh bundle.
                    appSafety.invalidate()
                    startSettings(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                    safe.success(null)
                }
                "uninstallApp" -> {
                    val pkg = call.argument<String>("package") ?: ""
                    if (pkg.isEmpty()) {
                        safe.error("bad_args", "package missing", null)
                    } else {
                        appSafety.invalidate()
                        uninstallApp(pkg)
                        safe.success(null)
                    }
                }
                "openSettingsPanel" -> {
                    val panel = call.argument<String>("panel") ?: ""
                    val pkg = call.argument<String>("package")
                    val intent = settingsPanelIntent(panel, pkg)
                    if (intent == null) {
                        safe.error("bad_args", "unknown panel", null)
                    } else {
                        appSafety.invalidate()
                        startSettings(intent)
                        safe.success(null)
                    }
                }
                "playPcm" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val rate = call.argument<Number>("sampleRate")?.toInt() ?: 24_000
                    if (bytes != null) pcm.write(bytes, rate)
                    safe.success(null)
                }
                "stopPcm" -> {
                    pcm.stop()
                    safe.success(null)
                }
                "enterVoiceSession" -> {
                    voiceSession?.enter()
                    safe.success(null)
                }
                "exitVoiceSession" -> {
                    voiceSession?.exit()
                    safe.success(null)
                }
                "requestPhoneStatePermission" -> requestPhoneStatePermission(safe)
                else -> safe.notImplemented()
            }
        } catch (t: Throwable) {
            safe.error("native_error", t.message ?: t.javaClass.simpleName, null)
        }
    }

    private fun background(
        result: MainThreadResult,
        on: ExecutorService = executor,
        work: () -> Any?,
    ) {
        try {
            on.execute {
                try {
                    result.success(work())
                } catch (t: Throwable) {
                    result.error("native_error", t.message ?: t.javaClass.simpleName, null)
                }
            }
        } catch (t: Throwable) {
            // Executor shut down (engine detached): answer rather than hang.
            result.error("native_error", t.message ?: t.javaClass.simpleName, null)
        }
    }

    /**
     * `{bundle, bundle_hash, integrity_token}`: the (cached) bundle, its
     * canonical SHA-256 and a token requested now for exactly that hash; the
     * token is never cached and is null when no provider is prepared.
     */
    private fun attestation(result: MainThreadResult) {
        try {
            executor.execute {
                try {
                    val snap = appSafety.snapshot()
                    val reply: (String?) -> Unit = { token ->
                        result.success(
                            mapOf(
                                "bundle" to snap.json,
                                "bundle_hash" to snap.hash,
                                "integrity_token" to token,
                            ),
                        )
                    }
                    if (integrity.isPrepared()) integrity.token(snap.hash, reply) else reply(null)
                } catch (t: Throwable) {
                    result.error("native_error", t.message ?: t.javaClass.simpleName, null)
                }
            }
        } catch (t: Throwable) {
            result.error("native_error", t.message ?: t.javaClass.simpleName, null)
        }
    }

    // ---------------------------------------------------------------- methods

    /** Applies [on] to the current activity; `false` when there is none. */
    private fun setSecure(on: Boolean): Boolean {
        val a = activity ?: return false
        return applySecure(a, on)
    }

    private fun applySecure(a: Activity, on: Boolean): Boolean {
        val window = a.window ?: return false
        if (on) {
            window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        (a as? MainActivity)?.secureMode = on
        try {
            window.decorView.filterTouchesWhenObscured = on
        } catch (_: Throwable) {
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                window.setHideOverlayWindows(on)
            } catch (_: Throwable) {
                // HIDE_OVERLAY_WINDOWS is in the manifest; some OEM builds still refuse.
            }
        }
        return true
    }

    private fun openAppDetails(pkg: String) {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(Uri.parse("package:$pkg"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val target: Context = activity ?: appContext
        target.startActivity(intent)
    }

    /** The system uninstall dialog; the app-info page when it cannot open. */
    private fun uninstallApp(pkg: String) {
        val intent = Intent(Intent.ACTION_DELETE)
            .setData(Uri.parse("package:$pkg"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val target: Context = activity ?: appContext
        try {
            target.startActivity(intent)
        } catch (_: Throwable) {
            openAppDetails(pkg)
        }
    }

    private fun settingsPanelIntent(panel: String, pkg: String?): Intent? = when (panel) {
        "overlay" -> Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION).apply {
            if (!pkg.isNullOrEmpty()) data = Uri.parse("package:$pkg")
        }
        "developer" -> Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
        "security" -> Intent(Settings.ACTION_SECURITY_SETTINGS)
        "cast" -> Intent(Settings.ACTION_CAST_SETTINGS)
        else -> null
    }

    /** Starts a settings page; the main settings screen when the OEM lacks it. */
    private fun startSettings(intent: Intent) {
        val target: Context = activity ?: appContext
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            target.startActivity(intent)
        } catch (_: Throwable) {
            target.startActivity(
                Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    private fun requestPhoneStatePermission(result: MainThreadResult) {
        val granted = ContextCompat.checkSelfPermission(
            appContext,
            Manifest.permission.READ_PHONE_STATE,
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success(true)
            return
        }
        val a = activity
        if (a == null) {
            result.success(false)
            return
        }
        val first = pendingPermissionResults.isEmpty()
        pendingPermissionResults.add(result)
        if (first) {
            ActivityCompat.requestPermissions(
                a,
                arrayOf(Manifest.permission.READ_PHONE_STATE),
                PHONE_STATE_REQUEST,
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PHONE_STATE_REQUEST) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        if (granted) signals.onPhoneStatePermissionChanged()
        val waiting = ArrayList(pendingPermissionResults)
        pendingPermissionResults.clear()
        waiting.forEach { it.success(granted) }
        return true
    }

    private fun failPendingPermissions() {
        val waiting = ArrayList(pendingPermissionResults)
        pendingPermissionResults.clear()
        waiting.forEach { it.success(false) }
    }

    /**
     * Posts every reply to the main looper and answers at most once, so
     * background code and Play Integrity callbacks can reply from any thread.
     */
    private class MainThreadResult(
        private val inner: MethodChannel.Result,
        private val handler: Handler,
    ) {
        private val lock = Any()
        private var answered = false

        private fun once(block: () -> Unit) {
            synchronized(lock) {
                if (answered) return
                answered = true
            }
            if (Looper.myLooper() == handler.looper) {
                block()
            } else {
                handler.post(block)
            }
        }

        fun success(value: Any?) = once {
            try {
                inner.success(value)
            } catch (_: Throwable) {
            }
        }

        fun error(code: String, message: String?, details: Any?) = once {
            try {
                inner.error(code, message, details)
            } catch (_: Throwable) {
            }
        }

        fun notImplemented() = once {
            try {
                inner.notImplemented()
            } catch (_: Throwable) {
            }
        }
    }
}
