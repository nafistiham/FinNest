package com.bhorosha.appsafety

import android.Manifest
import android.accessibilityservice.AccessibilityServiceInfo
import android.app.AppOpsManager
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.nfc.NfcAdapter
import android.nfc.cardemulation.CardEmulation
import android.nfc.cardemulation.HostApduService
import android.os.Build
import android.provider.Settings
import android.provider.Telephony
import android.service.notification.NotificationListenerService
import android.view.accessibility.AccessibilityManager
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant

/**
 * App Safety Check: builds the exact JSON body of `AppSafetyRequest` (risk-mw `app/contracts.py`):
 * `{installed_apps: [...], device: {...}, integrity_token}`.
 *
 * FR-1: this class never needs READ_SMS, RECEIVE_SMS, READ_CALL_LOG or QUERY_ALL_PACKAGES. Visibility comes only from
 * the manifest `<queries>` block (launcher, HCE, notification-listener and SMS intent filters plus the explicit
 * remote-access package list), see collector/README.md. Call [collect] off the main thread: one PackageManager round
 * trip per visible app.
 */
class AppSafetyCollector {

    companion object {
        const val CHANNEL = "bhorosha/appsafety"
        const val METHOD = "getAppSafetyBundle"

        /** GMS system package installer; the server classifies it as sideloaded (policy_rules.md section 6). */
        private const val GMS_INSTALLER = "com.google.android.packageinstaller"
        private val SYSTEM_INSTALLERS = setOf(
            GMS_INSTALLER, "com.android.packageinstaller", "com.android.permissioncontroller",
        )

        /** Stores never count as droppers; the server's section 6 list is authoritative, this only pre-filters. */
        private val STORE_INSTALLERS = setOf(
            "com.android.vending", "com.sec.android.app.samsungapps", "com.xiaomi.mipicks", "com.xiaomi.market",
            "com.huawei.appmarket", "com.oppo.market", "com.heytap.market", "com.vivo.appstore", "com.amazon.venezia",
        )

        /** `Settings.Secure` @hide key (flattened ComponentName), readable by string; best-effort only. */
        private const val NFC_PAYMENT_DEFAULT_SETTING = "nfc_payment_default_component"

        /**
         * Remote-access tools scammers talk victims into installing (policy_rules.md section 4,
         * "remote control" tier = KNOWN_RAT high; viewer-only clients left out on purpose).
         * Must match the `<package android:name=...>` entries in the manifest `<queries>` block,
         * otherwise getPackageInfo throws NameNotFoundException even when the app is installed.
         */
        val DECLARED_PACKAGES = listOf(
            "com.anydesk.anydeskandroid", "com.teamviewer.quicksupport.market", "com.teamviewer.host.market",
            "com.teamviewer.quicksupport.addon.universal", "com.carriez.flutter_hbb", "com.sand.airdroid",
            "com.sand.airsos", "com.sand.airmirror", "com.zoho.assist.agent", "com.splashtop.sos",
            "com.splashtop.streamer.csrs", "com.screenconnect.androidclient", "com.logmein.rescuemobile",
            "com.islonline.isllight.mobile.android", "com.teknopars.AlpemixPro", "it.nanosystems.Supremo",
            "com.demo.takanow", // US-5 demo fixture; it has a launcher activity anyway, listed for clarity
        )

        private val SU_PATHS = listOf(
            "/system/bin/su", "/system/xbin/su", "/sbin/su", "/system/su", "/su/bin/su",
            "/data/local/bin/su", "/data/local/xbin/su", "/data/local/su", "/system/sd/xbin/su",
        )

        /**
         * Canonical key order for [bundleHash]; MUST match the server's `bhorosha_app_safety_check.integrity.bundle_hash` (keys
         * sorted). Always send every key: the server hashes the parsed model with defaults, an omitted key hashes as null here.
         */
        private val APP_KEYS = listOf(
            "accessibility_enabled", "first_install", "has_accessibility_service", "has_hce_service",
            "has_notification_listener", "installer", "installer_declares_install_packages", "is_default_sms_app",
            "label", "launcher_icon_hidden", "package", "permissions", "target_sdk", "version",
        )
        private val DEVICE_KEYS = listOf(
            "adb", "default_sms_package", "dev_options", "device_admins", "nfc_default_payment_package",
            "overlay_holders", "play_protect", "rooted", "sdk_int",
        )
    }

    fun collect(context: Context): JSONObject {
        val pm = context.packageManager
        val self = context.packageName
        val enabledA11y = enabledAccessibilityPackages(context)
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val launcherPkgs = resolve(pm, Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), false)
            .map { it.activityInfo.packageName }.toSet()
        val hceServices = resolve(pm, Intent(HostApduService.SERVICE_INTERFACE), true)
        val hcePkgs = hceServices.mapNotNull { it.serviceInfo?.packageName }.toSet()
        val listenerPkgs = resolve(pm, Intent(NotificationListenerService.SERVICE_INTERFACE), true)
            .mapNotNull { it.serviceInfo?.packageName }.toSet()
        val defaultSms: String? = runCatching { Telephony.Sms.getDefaultSmsPackage(context) }.getOrNull()
        val dropperCache = HashMap<String, Boolean>()

        val apps = JSONArray()
        val overlayHolders = JSONArray()
        // Icon-hidden apps are only enumerable through the other `<queries>` routes (HCE, listener, SMS role, DECLARED_PACKAGES).
        val visible = launcherPkgs + DECLARED_PACKAGES + hcePkgs + listenerPkgs + listOfNotNull(defaultSms) - self
        for (pkg in visible) {
            val info = runCatching { packageInfo(pm, pkg) }.getOrNull() ?: continue
            val ai = info.applicationInfo ?: continue
            val isSystem = ai.flags and ApplicationInfo.FLAG_SYSTEM != 0
            val permissions = info.requestedPermissions?.toList().orEmpty()
            val services = info.services?.toList().orEmpty()
            apps.put(JSONObject().apply {
                put("package", pkg)
                put("label", pm.getApplicationLabel(ai).toString())
                put("installer", installer(pm, pkg, ai) ?: JSONObject.NULL)
                put("version", info.versionName ?: "") // contract: str, never null
                put("permissions", JSONArray(permissions))
                put("has_accessibility_service", services.any { it.permission == Manifest.permission.BIND_ACCESSIBILITY_SERVICE })
                put("accessibility_enabled", pkg in enabledA11y)
                put("target_sdk", ai.targetSdkVersion)
                put("first_install", Instant.ofEpochMilli(info.firstInstallTime).toString())
                // 2026 signals: research_notes threat_landscape_2026.md, Key Question 4 (KQ4). Facts only; the server scores.
                // KQ4 rule 4: a notification listener reads OTPs without READ_SMS (Crocodilus / Herodotus OTP theft).
                put("has_notification_listener", services.any { it.permission == Manifest.permission.BIND_NOTIFICATION_LISTENER_SERVICE })
                // KQ4 rule 5: NFC relay (Tap-and-Steal wave, PhantomCard, NGate, SuperCard X, RatOn) = a HostApduService.
                put("has_hce_service", pkg in hcePkgs)
                // KQ4 rule 4: ROLE_SMS takeover (Crocodilus `SpinderSpike`, Google's 2026 "SMS forwarding" warning).
                put("is_default_sms_app", pkg == defaultSms)
                // KQ4 rule 9: icon hiding after install (what Google's Pixel-only LTD keys on). TeamViewer add-ons legitimately
                // have no icon, so the server weighs this together with `installer`, never alone.
                put("launcher_icon_hidden", !isSystem && pkg !in launcherPkgs)
                // KQ4 rule 3: session-installer droppers (SecuriDropper, Zombinder, Herodotus com.cd3.app): the payload's
                // installer is a non-store app holding REQUEST_INSTALL_PACKAGES, so it never looks like "Unknown Sources".
                put("installer_declares_install_packages", installerIsDropper(pm, installingPackage(pm, pkg), dropperCache))
            })
            if (holdsOverlay(appOps, ai, permissions)) overlayHolders.put(pkg)
        }

        val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        val resolver = context.contentResolver
        val device = JSONObject().apply {
            put("overlay_holders", overlayHolders)
            put("device_admins", JSONArray(dpm.activeAdmins?.map { it.packageName }.orEmpty()))
            put("dev_options", Settings.Global.getInt(resolver, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) == 1)
            put("adb", Settings.Global.getInt(resolver, Settings.Global.ADB_ENABLED, 0) == 1)
            put("rooted", SU_PATHS.any { File(it).exists() } || Build.TAGS?.contains("test-keys") == true)
            // Play Protect's on/off state is not readable by a third-party app without Play Integrity
            // (the real signal is the `playProtectVerdict` in environmentDetails, decoded server-side).
            // Sending the contract default keeps the rules layer neutral until the token is decoded.
            put("play_protect", true)
            // KQ4 rule 13: sdk <= 31 lacks Restricted Settings / OTP redaction / in-call blocks; the server weights rules up.
            put("sdk_int", Build.VERSION.SDK_INT)
            put("default_sms_package", defaultSms ?: JSONObject.NULL)
            put("nfc_default_payment_package", nfcDefaultPaymentPackage(context, hceServices) ?: JSONObject.NULL)
        }

        return JSONObject().apply {
            put("installed_apps", apps)
            put("device", device)
            put("integrity_token", JSONObject.NULL) // filled by the caller, see [integrityToken]
        }
    }

    /** Visibility-filtered intent resolution; each intent used here needs a matching `<intent>` in `<queries>`. */
    @Suppress("DEPRECATION")
    private fun resolve(pm: PackageManager, intent: Intent, services: Boolean): List<ResolveInfo> =
        if (Build.VERSION.SDK_INT >= 33) {
            val flags = PackageManager.ResolveInfoFlags.of(0)
            if (services) pm.queryIntentServices(intent, flags) else pm.queryIntentActivities(intent, flags)
        } else if (services) pm.queryIntentServices(intent, 0) else pm.queryIntentActivities(intent, 0)

    @Suppress("DEPRECATION")
    private fun packageInfo(pm: PackageManager, pkg: String): PackageInfo {
        val flags = PackageManager.GET_PERMISSIONS or PackageManager.GET_SERVICES
        return if (Build.VERSION.SDK_INT >= 33) {
            pm.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(flags.toLong()))
        } else pm.getPackageInfo(pkg, flags)
    }

    /**
     * Installer of record as the server expects it: "system" for FLAG_SYSTEM apps, otherwise the installing package
     * name, falling back to `initiatingPackageName` so an adb install arrives as `com.android.shell` (sideloaded on the
     * server). Null only when the OS has no provenance at all (`packageSource` UNSPECIFIED and every name null), which is
     * what OEM partner preloads and Phone Clone restores look like; the server weighs that as "unknown origin, low"
     * (on one test phone, 19 of 80 apps looked like that).
     *
     * Android 15 CDD section 9.8 (Enhanced Confirmation Mode): "Covered Applications" are those installed with
     * PACKAGE_SOURCE_DOWNLOADED_FILE (browser/messaging) or PACKAGE_SOURCE_LOCAL_FILE (file manager), so on API 33+
     * `getPackageSource()` is the OS's own sideload verdict and beats installer-name matching. Browsers and file
     * managers usually appear as `originatingPackageName` while `installingPackageName` is the system package
     * installer, so we prefer the originating name whenever the installer of record is the system installer.
     * Caveat: `originatingPackageName` may be null for callers without INSTALL_PACKAGES; the fallback to
     * GMS_INSTALLER keeps the server classification "sideloaded" in that case.
     */
    @Suppress("DEPRECATION")
    private fun installer(pm: PackageManager, pkg: String, ai: ApplicationInfo): String? {
        if (ai.flags and ApplicationInfo.FLAG_SYSTEM != 0) return "system"
        if (Build.VERSION.SDK_INT < 30) return pm.getInstallerPackageName(pkg)
        val src = runCatching { pm.getInstallSourceInfo(pkg) }.getOrNull() ?: return null
        val installing = src.installingPackageName
        val originating = src.originatingPackageName
        val initiating = src.initiatingPackageName  // the session's caller: com.android.shell for adb, a store, a dropper
        if (Build.VERSION.SDK_INT >= 33 && (src.packageSource == PackageInstaller.PACKAGE_SOURCE_DOWNLOADED_FILE ||
                src.packageSource == PackageInstaller.PACKAGE_SOURCE_LOCAL_FILE)) {
            return originating ?: installing?.takeIf { it in SYSTEM_INSTALLERS } ?: GMS_INSTALLER
        }
        val ofRecord = if (installing in SYSTEM_INSTALLERS && originating != null) originating else installing
        return ofRecord ?: initiating
    }

    /** Raw installer of record (the session-installer caller), unlike [installer] which prefers the originating app. */
    @Suppress("DEPRECATION")
    private fun installingPackage(pm: PackageManager, pkg: String): String? = runCatching {
        if (Build.VERSION.SDK_INT >= 30) pm.getInstallSourceInfo(pkg).installingPackageName else pm.getInstallerPackageName(pkg)
    }.getOrNull()

    /**
     * Dropper pattern (KQ4 rule 3): installer is a visible, non-system, non-store app declaring REQUEST_INSTALL_PACKAGES.
     * An installer outside `<queries>` cannot be inspected and yields false (plain bool in the contract): under-reports.
     */
    private fun installerIsDropper(pm: PackageManager, installer: String?, cache: MutableMap<String, Boolean>): Boolean {
        if (installer == null || installer in STORE_INSTALLERS || installer in SYSTEM_INSTALLERS) return false
        return cache.getOrPut(installer) {
            val info = runCatching { packageInfo(pm, installer) }.getOrNull() ?: return@getOrPut false
            val system = (info.applicationInfo?.flags ?: 0) and ApplicationInfo.FLAG_SYSTEM != 0
            !system && Manifest.permission.REQUEST_INSTALL_PACKAGES in info.requestedPermissions.orEmpty()
        }
    }

    /**
     * Package of the default NFC payment service (KQ4 rule 5: relay malware makes itself the default). Limitation:
     * `CardEmulation.isDefaultServiceForCategory` is per-component, so only the HostApduServices we can see are tested;
     * default outside `<queries>`, no NFC/HCE, or missing the normal `android.permission.NFC` all give null ("unknown",
     * never "none"). The @hide `Settings.Secure` key is a best-effort fallback that OEM builds may leave empty.
     */
    private fun nfcDefaultPaymentPackage(context: Context, hceServices: List<ResolveInfo>): String? {
        val adapter = NfcAdapter.getDefaultAdapter(context) ?: return null
        val ce = runCatching { CardEmulation.getInstance(adapter) }.getOrNull() ?: return null
        val seen = hceServices.firstOrNull { ri ->
            val si = ri.serviceInfo ?: return@firstOrNull false
            runCatching {
                ce.isDefaultServiceForCategory(ComponentName(si.packageName, si.name), CardEmulation.CATEGORY_PAYMENT)
            }.getOrDefault(false)
        }?.serviceInfo?.packageName
        return seen ?: runCatching { Settings.Secure.getString(context.contentResolver, NFC_PAYMENT_DEFAULT_SETTING) }
            .getOrNull()?.let { ComponentName.unflattenFromString(it)?.packageName }
    }

    /**
     * Packages whose accessibility service is switched on right now. A sideloaded app with an enabled service on
     * Android 13+ means the user walked through "Allow restricted settings" (Settings > Apps > [app] > menu,
     * https://support.google.com/android/answer/12623953), scored SIDELOADED_ACCESSIBILITY critical by the server.
     * Open question from the spec: whether this list is visibility-filtered on API 30+; verify on device.
     */
    private fun enabledAccessibilityPackages(context: Context): Set<String> {
        val am = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as AccessibilityManager
        return am.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
            .mapNotNull { it.resolveInfo?.serviceInfo?.packageName }.toSet()
    }

    /**
     * "Display over other apps" holder. Android 15 CDD 9.8 lists OPSTR_SYSTEM_ALERT_WINDOW among the settings ECM
     * blocks for sideloaded apps; overlay plus accessibility is the classic banking-trojan pair. AppOps is the source
     * of truth; if the op check is refused we fall back to the declared permission (over-reports, flagged in README).
     */
    private fun holdsOverlay(appOps: AppOpsManager, ai: ApplicationInfo, permissions: List<String>): Boolean {
        val declared = Manifest.permission.SYSTEM_ALERT_WINDOW in permissions
        if (!declared) return false
        @Suppress("DEPRECATION")
        val mode = runCatching {
            if (Build.VERSION.SDK_INT >= 29) {
                appOps.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_SYSTEM_ALERT_WINDOW, ai.uid, ai.packageName)
            } else appOps.checkOpNoThrow(AppOpsManager.OPSTR_SYSTEM_ALERT_WINDOW, ai.uid, ai.packageName)
        }.getOrNull() ?: return declared
        return mode == AppOpsManager.MODE_ALLOWED
    }

    /**
     * SHA-256 (hex) over the canonical JSON of the bundle, byte-identical to the server's
     * `bhorosha_app_safety_check.integrity.bundle_hash`: apps sorted by package, string arrays sorted, keys sorted
     * ([APP_KEYS] / [DEVICE_KEYS]), booleans as true/false, null as null, integers (`target_sdk`, `sdk_int`) as
     * digits, compact separators, UTF-8, no escaping of non-ASCII. Put it in the Play Integrity requestHash (or
     * send it to /v1/appsafety/demo-token) so the token becomes a signature over exactly this evidence; the
     * server recomputes it from what it receives and treats a mismatch as a tampered client.
     */
    fun bundleHash(bundle: JSONObject): String {
        val apps = bundle.getJSONArray("installed_apps")
        val rows = (0 until apps.length()).map { apps.getJSONObject(it) }.sortedBy { it.getString("package") }
        val canon = "{\"device\":" + canonical(bundle.getJSONObject("device"), DEVICE_KEYS) +
            ",\"installed_apps\":" + rows.joinToString(",", "[", "]") { canonical(it, APP_KEYS) } + "}"
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(canon.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }

    /** One object in canonical form: the given key order, string arrays sorted, absent keys as null. */
    private fun canonical(o: JSONObject, keys: List<String>): String =
        keys.joinToString(",", "{", "}") { k -> jsonString(k) + ":" + canonicalValue(o.opt(k)) }

    private fun canonicalValue(v: Any?): String = when (v) {
        null, JSONObject.NULL -> "null"
        is String -> jsonString(v)
        is JSONArray -> sortedArray(v)
        else -> v.toString() // Boolean -> true/false, Int -> digits, same as Python json.dumps
    }

    private fun sortedArray(arr: JSONArray): String =
        (0 until arr.length()).map { arr.getString(it) }.sorted().joinToString(",", "[", "]") { jsonString(it) }

    /** Python json.dumps(ensure_ascii=False) escaping: only `"`, `\\` and control characters. */
    private fun jsonString(s: String): String {
        val out = StringBuilder("\"")
        for (ch in s) when {
            ch == '"' -> out.append("\\\"")
            ch == '\\' -> out.append("\\\\")
            ch == '\n' -> out.append("\\n")
            ch == '\r' -> out.append("\\r")
            ch == '\t' -> out.append("\\t")
            ch < ' ' -> out.append(String.format("\\u%04x", ch.code))
            else -> out.append(ch)
        }
        return out.append('"').toString()
    }

    /**
     * Play Integrity token for `integrity_token` (US-4). Stub so this file compiles without the
     * `com.google.android.play:integrity` dependency; the real body is:
     *
     * ```
     * val manager = IntegrityManagerFactory.createStandard(context)
     * manager.prepareIntegrityToken(
     *     PrepareIntegrityTokenRequest.builder().setCloudProjectNumber(CLOUD_PROJECT_NUMBER).build()
     * ).addOnSuccessListener { provider ->
     *     provider.request(StandardIntegrityTokenRequest.builder().setRequestHash(requestHash).build())
     *         .addOnSuccessListener { onToken(it.token()) }
     *         .addOnFailureListener { onToken(null) }
     * }.addOnFailureListener { onToken(null) }
     * ```
     * `requestHash` = [bundleHash] of the bundle about to be sent (not the transfer), so the server can bind the
     * verdict to this check. `environmentDetails` (appAccessRiskVerdict, playProtectVerdict) is an opt-in in Play
     * Console; the server decodes it (`UNKNOWN_CONTROLLING` -> BLOCK).
     * Demo mode (prototype not on Play): the Flutter demo panel asks the server-side demo token builder for a signed
     * synthetic verdict instead; `demo.<base64url json>.<hmac>` is owned by the server team, the app forwards it as is.
     */
    fun integrityToken(context: Context, requestHash: String, onToken: (String?) -> Unit) {
        onToken(null) // TODO: wire Play Integrity once the app has a Play listing / project number
    }
}
