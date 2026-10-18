package com.bhorosha.app.native

import android.content.Context
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityManager
import com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityToken
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenProvider
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest

/**
 * Play Integrity standard requests, off the critical path.
 *
 * [prepare] warms a token provider at app start; [token] answers with the
 * token or `null` whenever the provider is missing or Play fails (emulator
 * without Play, no network, project number not set). Nothing here blocks: the
 * Play tasks complete on their own threads and the callback is invoked there,
 * so callers post back to the main looper themselves.
 */
class Integrity(private val context: Context) {
    @Volatile private var provider: StandardIntegrityTokenProvider? = null
    @Volatile private var preparing = false

    fun prepare(cloudProjectNumber: Long) {
        if (cloudProjectNumber <= 0L || preparing || provider != null) return
        preparing = true
        try {
            val manager: StandardIntegrityManager = IntegrityManagerFactory.createStandard(context)
            manager.prepareIntegrityToken(
                PrepareIntegrityTokenRequest.builder()
                    .setCloudProjectNumber(cloudProjectNumber)
                    .build(),
            )
                .addOnSuccessListener { p ->
                    provider = p
                    preparing = false
                }
                .addOnFailureListener { preparing = false }
        } catch (_: Throwable) {
            preparing = false
        }
    }

    fun isPrepared(): Boolean = provider != null

    fun token(requestHash: String, callback: (String?) -> Unit) {
        val p = provider
        if (p == null) {
            callback(null)
            return
        }
        try {
            p.request(
                StandardIntegrityTokenRequest.builder()
                    .setRequestHash(requestHash)
                    .build(),
            )
                .addOnSuccessListener { t: StandardIntegrityToken -> callback(t.token()) }
                .addOnFailureListener { callback(null) }
        } catch (_: Throwable) {
            callback(null)
        }
    }
}
