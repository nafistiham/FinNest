package com.bhorosha.app.native

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import com.bhorosha.app.BuildConfig
import com.bhorosha.appsafety.AppSafetyCollector
import org.json.JSONObject

/**
 * Per-process 60 s cache around the App Safety collector
 * (`com.bhorosha.appsafety.AppSafetyCollector`, copied verbatim). The collector is the single implementation of the scan;
 * this class only memoises its JSON string and canonical hash so the Home
 * badge and the demo panel do not rescan on every visit. Integrity tokens are
 * never cached here (see the plugin's `getAppSafetyAttestation`).
 *
 * Always call from the plugin executor: the scan does one PackageManager
 * round trip per visible app.
 */
class AppSafety(private val context: Context) {
    companion object {
        private const val CACHE_MS = 60_000L
        private const val TAG = "BhoroshaAppSafety"
    }

    /** The `AppSafetyRequest` body as JSON plus its `bundleHash` (Play Integrity requestHash). */
    data class Snapshot(val json: String, val hash: String)

    private val collector = AppSafetyCollector()
    private val lock = Any()
    private var cached: Snapshot? = null
    private var cachedAt = 0L

    fun snapshot(): Snapshot {
        synchronized(lock) {
            val c = cached
            if (c != null && System.currentTimeMillis() - cachedAt < CACHE_MS) return c
        }
        val started = System.currentTimeMillis()
        val bundle = collector.collect(context)
        val fresh = Snapshot(bundle.toString(), collector.bundleHash(bundle))
        synchronized(lock) {
            cached = fresh
            cachedAt = System.currentTimeMillis()
        }
        Log.i(TAG, "collect took ${System.currentTimeMillis() - started} ms, body ${fresh.json.length} chars")
        // Package names and install sources stay out of release logcat;
        // skipping it in release also saves two PackageManager calls per app.
        if (BuildConfig.DEBUG) logNullInstallers(bundle)
        return fresh
    }

    /**
     * Diagnostic: apps the collector reports with
     * `installer == null` are scored as unknown origin (sideloaded), but on OEM phones
     * they are often partner preloads or Phone Clone restores. Log what the OS knows
     * so the policy can be decided on evidence. Logcat tag [TAG]; never sent anywhere.
     * Debug builds only: the caller guards it with `BuildConfig.DEBUG`.
     */
    private fun logNullInstallers(bundle: JSONObject) {
        if (Build.VERSION.SDK_INT < 30) return
        val pm = context.packageManager
        val apps = bundle.optJSONArray("installed_apps") ?: return
        for (i in 0 until apps.length()) {
            val app = apps.optJSONObject(i) ?: continue
            if (!app.isNull("installer")) continue
            val pkg = app.optString("package")
            val src = runCatching { pm.getInstallSourceInfo(pkg) }.getOrNull()
            val source = if (Build.VERSION.SDK_INT >= 33) src?.packageSource else null
            val system = runCatching {
                pm.getApplicationInfo(pkg, 0).flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM != 0
            }.getOrDefault(false)
            Log.i(
                TAG,
                "null-installer pkg=$pkg initiating=${src?.initiatingPackageName} " +
                    "originating=${src?.originatingPackageName} installing=${src?.installingPackageName} " +
                    "packageSource=$source system=$system",
            )
        }
    }

    /** The exact `AppSafetyRequest` body as a JSON string (`integrity_token` null). */
    fun bundleJson(): String = snapshot().json

    fun invalidate() {
        synchronized(lock) { cached = null }
    }
}
