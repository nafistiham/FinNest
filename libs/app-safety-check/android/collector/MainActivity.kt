package com.bhorosha.app // use the Flutter project's applicationId package

import android.os.Handler
import android.os.Looper
import com.bhorosha.appsafety.AppSafetyCollector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Registers the `bhorosha/appsafety` MethodChannel. `getAppSafetyBundle` runs the collector on a
 * worker thread (one PackageManager round trip per visible app, keep it off the UI thread) and
 * replies with the `AppSafetyRequest` JSON as a string; Dart does `jsonDecode` and POSTs it.
 */
class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val collector = AppSafetyCollector()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AppSafetyCollector.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    AppSafetyCollector.METHOD -> worker.execute {
                        val outcome = runCatching { collector.collect(applicationContext).toString() }
                        main.post { // MethodChannel.Result must be completed on the main thread
                            outcome.fold(
                                onSuccess = { result.success(it) },
                                onFailure = { result.error("collect_failed", it.message, null) },
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        worker.shutdown()
        super.onDestroy()
    }
}
