package com.bhorosha.app.native

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Streams 16-bit mono PCM (Apa's Live audio, 24 kHz) through one [AudioTrack].
 *
 * Writes are serialised on a private single-thread executor so a blocking
 * `AudioTrack.write` never stalls the main thread and chunks keep their order.
 *
 * [stop] must not wait behind those writes (the user pressed hold-to-talk and
 * Apa has to go quiet now): it bumps a volatile stop generation that every
 * queued and running write checks, and pauses and flushes the track at once
 * from the caller's thread, which also unblocks a `write` in progress.
 *
 * Drained signal: every write moves the track's notification marker
 * to the total frame count written to that track. When the play head reaches
 * the marker and no newer write is queued, [onDrained] runs on [callbackHandler]'s
 * thread. A [stop] (or a track recreated for a new rate) starts the count
 * again, and nothing is reported after a stop until the next write.
 */
class PcmPlayer(
    private val callbackHandler: Handler = Handler(Looper.getMainLooper()),
    /**
     * `true` while the FNA voice session owns the audio mode (it set
     * `MODE_IN_COMMUNICATION` itself): the track then uses
     * `USAGE_VOICE_COMMUNICATION` so the platform echo canceller hears it.
     * Otherwise (Apa's old voice path, or FNA opened during a real call that
     * owns the mode) `USAGE_ASSISTANT` on the media route, never the earpiece.
     */
    private val inVoiceSession: () -> Boolean = { false },
    private val onDrained: () -> Unit = {},
) {
    private val audioExecutor: ExecutorService =
        Executors.newSingleThreadExecutor { r -> Thread(r, "bhorosha-pcm") }

    @Volatile
    private var track: AudioTrack? = null
    private var trackSampleRate = 0
    private var trackUsage = -1

    /** Bumped by [stop]; a write enqueued under an older value is dropped. */
    @Volatile
    private var stopGeneration = 0

    /** Frames written to the current [track]; touched only on the audio thread. */
    private var framesWritten = 0L

    /** Writes accepted by [write] that have not finished yet (queued or running). */
    private val pendingWrites = AtomicInteger(0)

    /** Stop generation the current marker was set under. */
    @Volatile
    private var markerGeneration = -1

    /** Appends [bytes] to the stream, (re)creating the track when the rate changes. */
    fun write(bytes: ByteArray, sampleRate: Int) {
        if (bytes.isEmpty() || sampleRate <= 0) return
        val generation = stopGeneration
        pendingWrites.incrementAndGet()
        try {
            audioExecutor.execute {
                try {
                    if (generation != stopGeneration) return@execute
                    val t = ensureTrack(sampleRate)
                    var offset = 0
                    while (offset < bytes.size && generation == stopGeneration) {
                        val written = t.write(bytes, offset, bytes.size - offset)
                        if (written <= 0) break
                        offset += written
                    }
                    if (offset > 0 && generation == stopGeneration) {
                        framesWritten += offset / BYTES_PER_FRAME
                        markerGeneration = generation
                        // The marker is an Int frame position on the track.
                        t.setNotificationMarkerPosition(
                            framesWritten.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                        )
                    }
                } catch (_: Throwable) {
                    // Audio is best-effort: the on-screen text is the source of truth.
                } finally {
                    pendingWrites.decrementAndGet()
                }
            }
        } catch (_: Throwable) {
            // Executor shut down (plugin detached).
            pendingWrites.decrementAndGet()
        }
    }

    /** Silences now, drops queued chunks, then releases the track. Safe when idle. */
    fun stop() {
        stopGeneration++
        markerGeneration = -1
        track?.let { t ->
            try {
                t.pause()
                t.flush()
            } catch (_: Throwable) {
            }
        }
        audioExecutor.execute { releaseTrack() }
    }

    /** Releases the executor; call once when the plugin leaves the engine. */
    fun dispose() {
        stopGeneration++
        audioExecutor.execute { releaseTrack() }
        audioExecutor.shutdown()
    }

    private fun ensureTrack(sampleRate: Int): AudioTrack {
        val usage = if (safeBool(inVoiceSession)) {
            AudioAttributes.USAGE_VOICE_COMMUNICATION
        } else {
            AudioAttributes.USAGE_ASSISTANT
        }
        val existing = track
        if (existing != null && trackSampleRate == sampleRate && trackUsage == usage &&
            existing.state == AudioTrack.STATE_INITIALIZED
        ) {
            return existing
        }
        releaseTrack()
        val minBuffer = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        // Half a second of audio or the device minimum, whichever is larger.
        val bufferBytes = maxOf(minBuffer, sampleRate /* 2 bytes * 0.5 s */)
        val attributes = AudioAttributes.Builder()
            // Voice communication inside the FNA voice session: the platform
            // echo canceller hears FNA. Assistant otherwise.
            .setUsage(usage)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(sampleRate)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build()
        val created = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(format)
            .setBufferSizeInBytes(bufferBytes)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        created.setPlaybackPositionUpdateListener(
            object : AudioTrack.OnPlaybackPositionUpdateListener {
                override fun onMarkerReached(t: AudioTrack) = onMarker(t)
                override fun onPeriodicNotification(t: AudioTrack) {}
            },
            callbackHandler,
        )
        created.play()
        track = created
        trackSampleRate = sampleRate
        trackUsage = usage
        framesWritten = 0L
        return created
    }

    /** Marker reached: report "drained" unless a stop or a newer write came since. */
    private fun onMarker(t: AudioTrack) {
        if (t !== track) return
        if (markerGeneration != stopGeneration) return
        if (pendingWrites.get() != 0) return
        try {
            onDrained()
        } catch (_: Throwable) {
        }
    }

    private fun releaseTrack() {
        val t = track ?: return
        track = null
        trackSampleRate = 0
        trackUsage = -1
        framesWritten = 0L
        try {
            t.setPlaybackPositionUpdateListener(null)
        } catch (_: Throwable) {
        }
        try {
            if (t.playState != AudioTrack.PLAYSTATE_STOPPED) {
                t.pause()
                t.flush()
                t.stop()
            }
        } catch (_: Throwable) {
        } finally {
            try {
                t.release()
            } catch (_: Throwable) {
            }
        }
    }

    private fun safeBool(f: () -> Boolean): Boolean =
        try {
            f()
        } catch (_: Throwable) {
            false
        }

    private companion object {
        /** 16-bit mono. */
        const val BYTES_PER_FRAME = 2
    }
}
