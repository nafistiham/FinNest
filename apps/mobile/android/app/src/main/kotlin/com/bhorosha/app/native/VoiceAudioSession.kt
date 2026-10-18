package com.bhorosha.app.native

import android.app.Activity
import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build

/**
 * The one owner of the audio mode during an FNA voice session.
 *
 * [enter] puts the phone in `MODE_IN_COMMUNICATION`, so the platform echo
 * canceller hears FNA's voice, and forces the built-in loudspeaker, because
 * call mode routes to the earpiece by default. The volume keys then change the
 * voice-call stream. [exit] puts back only what [enter] changed.
 *
 * The audio mode is device-wide. When [enter] finds a mode other than
 * `MODE_NORMAL` (a real phone call or another VoIP app owns it), it changes
 * neither the mode nor the routing, so [exit] has nothing to restore there and
 * never leaves the phone in communication mode after that call ends.
 *
 * No audio focus is requested: the recorder runs with interruption "none" and
 * FNA's voice must not pause other audio for longer than the session itself.
 *
 * Both calls are idempotent and run on the main thread (method channel).
 */
class VoiceAudioSession(context: Context) {

    private val audioManager: AudioManager? =
        context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    private var active = false
    private var activity: Activity? = null

    /** `true` when [enter] switched NORMAL -> IN_COMMUNICATION (we own the mode). */
    private var ownsMode = false

    /** `true` when [enter] set a communication device (API 31+). */
    private var setCommunicationDevice = false

    /** `true` when [enter] forced the deprecated speakerphone flag. */
    private var forcedSpeakerphone = false
    private var savedSpeakerphone = false
    private var savedVolumeStream = AudioManager.USE_DEFAULT_STREAM_TYPE

    @Synchronized
    fun isActive(): Boolean = active

    /**
     * `true` while the session is active and [enter] set the communication
     * mode itself. When a real call owned the mode, this stays `false`, so the
     * player keeps the media route and FNA's voice does not go to the earpiece.
     */
    @Synchronized
    fun ownsMode(): Boolean = active && ownsMode

    /** The activity whose volume keys follow the session; `null` when detached. */
    @Synchronized
    fun setActivity(a: Activity?) {
        if (a === activity) return
        activity = a
        if (active && a != null) {
            savedVolumeStream = safe(AudioManager.USE_DEFAULT_STREAM_TYPE) { a.volumeControlStream }
            safe(Unit) { a.volumeControlStream = AudioManager.STREAM_VOICE_CALL }
        }
    }

    @Synchronized
    fun enter() {
        if (active) return
        val am = audioManager ?: return
        active = true
        ownsMode = false
        setCommunicationDevice = false
        forcedSpeakerphone = false
        val current = safe(AudioManager.MODE_NORMAL) { am.mode }
        if (current == AudioManager.MODE_NORMAL) {
            @Suppress("DEPRECATION")
            savedSpeakerphone = safe(false) { am.isSpeakerphoneOn }
            safe(Unit) { am.mode = AudioManager.MODE_IN_COMMUNICATION }
            ownsMode = safe(false) { am.mode == AudioManager.MODE_IN_COMMUNICATION }
            if (ownsMode) forceLoudspeaker(am)
        }
        // Another owner (a call): leave the mode and the routing alone.

        activity?.let { a ->
            savedVolumeStream = safe(AudioManager.USE_DEFAULT_STREAM_TYPE) { a.volumeControlStream }
            safe(Unit) { a.volumeControlStream = AudioManager.STREAM_VOICE_CALL }
        }
    }

    @Synchronized
    fun exit() {
        if (!active) return
        active = false
        val am = audioManager
        if (am != null) {
            if (setCommunicationDevice && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                safe(Unit) { am.clearCommunicationDevice() }
            }
            if (forcedSpeakerphone) {
                @Suppress("DEPRECATION")
                safe(Unit) { am.isSpeakerphoneOn = savedSpeakerphone }
            }
            // Only the mode we set: a call that started meanwhile keeps its own.
            if (ownsMode &&
                safe(AudioManager.MODE_NORMAL) { am.mode } == AudioManager.MODE_IN_COMMUNICATION
            ) {
                safe(Unit) { am.mode = AudioManager.MODE_NORMAL }
            }
        }
        ownsMode = false
        setCommunicationDevice = false
        forcedSpeakerphone = false
        activity?.let { a -> safe(Unit) { a.volumeControlStream = savedVolumeStream } }
        savedVolumeStream = AudioManager.USE_DEFAULT_STREAM_TYPE
    }

    private fun forceLoudspeaker(am: AudioManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val speaker = safe(null) {
                am.availableCommunicationDevices.firstOrNull {
                    it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                }
            }
            val routed = speaker != null && safe(false) { am.setCommunicationDevice(speaker) }
            if (routed) {
                setCommunicationDevice = true
                return
            }
        }
        @Suppress("DEPRECATION")
        safe(Unit) { am.isSpeakerphoneOn = true }
        forcedSpeakerphone = true
    }

    /** Audio routing is best-effort: an OEM refusal must never crash the call. */
    private inline fun <T> safe(fallback: T, block: () -> T): T =
        try {
            block()
        } catch (_: Throwable) {
            fallback
        }
}
