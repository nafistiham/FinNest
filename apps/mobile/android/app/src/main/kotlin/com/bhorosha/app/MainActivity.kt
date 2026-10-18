package com.bhorosha.app

import android.view.MotionEvent
import com.bhorosha.app.native.BhoroshaNativePlugin
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * FlutterFragmentActivity so biometric and credential prompts can attach.
 *
 * Obscured-touch filtering (FR-5): while secure mode is on, touches arriving
 * through an overlay window are dropped and reported to Flutter. The native
 * plugin (Task 4) sets [secureMode] and [onObscuredTouch].
 */
class MainActivity : FlutterFragmentActivity() {
    @Volatile var secureMode: Boolean = false
    var onObscuredTouch: (() -> Unit)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The bhorosha_native channel; not a pub package, so it is
        // registered here rather than by GeneratedPluginRegistrant.
        flutterEngine.plugins.add(BhoroshaNativePlugin())
    }

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (secureMode) {
            val obscured = ev.flags and MotionEvent.FLAG_WINDOW_IS_OBSCURED != 0 ||
                ev.flags and MotionEvent.FLAG_WINDOW_IS_PARTIALLY_OBSCURED != 0
            if (obscured) {
                if (ev.actionMasked == MotionEvent.ACTION_DOWN) onObscuredTouch?.invoke()
                return true
            }
        }
        return super.dispatchTouchEvent(ev)
    }
}
