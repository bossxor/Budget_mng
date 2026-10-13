package com.bossxor.jumeoni

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * 알림이 들어오면 화면 없이 Dart 파서(backgroundMain)를 돌려 raw 알림을 거래로 바꾼다.
 * 이미 실행 중이면 끝난 뒤 한 번 더 돈다. 실패해도 원문은 남아 있어 앱을 열 때 처리된다.
 */
object IngestRunner {
    private val main = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var rerun = false

    fun run(ctx: Context) {
        val app = ctx.applicationContext
        main.post {
            if (engine != null) {
                rerun = true
                return@post
            }
            try {
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(app)
                loader.ensureInitializationComplete(app, null)
                val e = FlutterEngine(app)
                engine = e
                MethodChannel(e.dartExecutor.binaryMessenger, "jumeoni/bg")
                    .setMethodCallHandler { call, result ->
                        if (call.method == "done") {
                            result.success(null)
                            finish(app, e)
                        } else {
                            result.notImplemented()
                        }
                    }
                e.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "backgroundMain")
                )
                // 안전장치: 30초 안에 끝나지 않으면 엔진을 정리한다.
                main.postDelayed({ finish(app, e) }, 30_000)
            } catch (_: Throwable) {
                engine = null
            }
        }
    }

    private fun finish(app: Context, e: FlutterEngine) {
        if (engine !== e) return
        engine = null
        e.destroy()
        if (rerun) {
            rerun = false
            run(app)
        }
    }
}
