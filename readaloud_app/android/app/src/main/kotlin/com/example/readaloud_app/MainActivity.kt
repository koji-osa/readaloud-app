package com.example.readaloud_app

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * No.94 Share Event Architecture（Architecture Z、
 * `No94_ShareEvent_Architecture_Design_20260908_v3.md` +
 * `_v3_addendum.md`参照）。
 *
 * 【MainActivity hard invariant】
 * MainActivityは`ACTION_SEND`/`ACTION_PROCESS_TEXT`のraw external
 * payloadを**一切authoritative captureしない**（`EXTRA_TEXT`/
 * `EXTRA_PROCESS_TEXT`を読むコードはこのclassに存在しない）。
 * これらのintent-filterは[ExternalInputEntryActivity]へ完全に
 * 移動済みであり、MainActivityの責務は以下のみに限定される:
 *
 * - Flutter/UI host（[AudioServiceActivity]、cached/shared
 *   FlutterEngine）
 * - launcher（`ACTION_MAIN`/`LAUNCHER`）
 * - AudioService host
 * - [ExternalInputEntryActivity]からのforwarding wake target
 * - 統合MethodChannel（[EXTERNAL_INPUT_METHOD_CHANNEL]）のprovider、
 *   および pending存在時のnotification-only通知
 *
 * このinvariantにより、旧versionでACTION_SENDをbase Intentとして
 * 作られたtaskがアップデート後に復元されても（legacy task
 * migration）、MainActivity側にそのcontentを読み取る能力自体が
 * 存在しないため、構造的にNO DELIVERYとなる（fingerprint/history
 * database等の追加ロジックは一切不要）。
 *
 * 【Native notification ownership】
 * - Cold path: [ExternalInputEntryActivity]がcapture→本Activityを
 *   起動→`super.onCreate()`内で[configureFlutterEngine]が呼ばれ、
 *   統合channel作成直後にpending存在を確認し、あれば
 *   `externalInputAvailable`を通知する。
 * - Warm path: [ExternalInputEntryActivity]がcapture→本Activityの
 *   既存instanceへ[onNewIntent]→pending存在を確認し、あれば通知する。
 *   `onNewIntent`はforwarding Intentの内容を一切読まない
 *   （wake eventのtriggerとしてのみ利用する、汎用的な
 *   「pullしに来てよい」シグナル）。
 *
 * Dart側にはstartup pull fallbackも維持されており（
 * `lib/util/external_input_handler.dart`）、cold start時に通知が
 * Dart側handler登録より先に発生して消失しても、pending payloadは
 * [ExternalInputPendingStore]に残るためstartup pullで回収される
 * （5709c892のEvent 2 fixの本質——native pending + notification-only
 * + Dart single-consumer atomic pull——をそのまま維持）。
 *
 * Persistent Share Observability Phase 1（[NativeShareObservability]）
 * は引き続き維持する。
 */
class MainActivity : AudioServiceActivity() {
    // configureFlutterEngine()のたびに再生成される（cached engineでも
    // Activity attachのたびに新しいMethodChannelインスタンスを作り直す。
    // Dart側のhandler登録自体はDart isolateの生存期間中1回のみで、
    // channel名が同じであれば新しいMethodChannelインスタンスからの
    // invokeMethod()も正しく届く）。
    private var externalInputMethodChannel: MethodChannel? = null

    // Persistent Share Observability Phase 1: このActivityインスタンスを
    // 識別するID（本文を含まない、process内identity）。Activity再生成
    // （cached engineでのActivityだけの再生成等）の前後を区別するために使う。
    private val activityInstanceId = System.identityHashCode(this)

    // getNativeShareLogSnapshot()の応答をmain threadへpostするためのHandler。
    // MethodChannel.Resultはmain thread(platform thread)から呼ぶ前提のため。
    private val mainHandler = Handler(Looper.getMainLooper())

    private val nativeObservability: NativeShareObservability
        get() = NativeShareObservability.getInstance(applicationContext)

    override fun onCreate(savedInstanceState: Bundle?) {
        nativeObservability.logEvent(
            "activity_lifecycle",
            mapOf(
                "stage" to "on_create_enter",
                "activityInstanceId" to activityInstanceId,
                "taskId" to taskId,
                "isTaskRoot" to isTaskRoot,
                "savedInstanceStatePresent" to (savedInstanceState != null),
            ),
        )
        // super.onCreate()の中でconfigureFlutterEngine()が呼ばれ、
        // externalInputMethodChannelがセットされたうえで通知が試みられる
        // （cached engineでDartが既に生存していれば、ここで即座に届く）。
        super.onCreate(savedInstanceState)
        nativeObservability.logEvent(
            "activity_lifecycle",
            mapOf("stage" to "on_create_exit", "activityInstanceId" to activityInstanceId),
        )
    }

    override fun onStart() {
        super.onStart()
        nativeObservability.logEvent(
            "activity_lifecycle",
            mapOf("stage" to "on_start", "activityInstanceId" to activityInstanceId),
        )
    }

    override fun onResume() {
        super.onResume()
        nativeObservability.logEvent(
            "activity_lifecycle",
            mapOf("stage" to "on_resume", "activityInstanceId" to activityInstanceId),
        )
    }

    override fun onPause() {
        super.onPause()
        nativeObservability.logEvent(
            "activity_lifecycle",
            mapOf("stage" to "on_pause", "activityInstanceId" to activityInstanceId),
        )
    }

    override fun onStop() {
        super.onStop()
        nativeObservability.logEvent(
            "activity_lifecycle",
            mapOf("stage" to "on_stop", "activityInstanceId" to activityInstanceId),
        )
    }

    override fun onDestroy() {
        nativeObservability.logEvent(
            "activity_lifecycle",
            mapOf(
                "stage" to "on_destroy",
                "activityInstanceId" to activityInstanceId,
                "isFinishing" to isFinishing,
                "isChangingConfigurations" to isChangingConfigurations,
            ),
        )
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        nativeObservability.logEvent(
            "activity_lifecycle",
            mapOf("stage" to "on_new_intent_enter", "activityInstanceId" to activityInstanceId),
        )
        super.onNewIntent(intent)
        // onNewIntent()ではconfigureFlutterEngine()は再度呼ばれない
        // （Activity-engineの接続は既に確立済みのため）。そのためここで
        // 明示的に通知を試みる。このIntentの内容自体は一切読まない
        // （class doc「Native notification ownership」参照。
        // ExternalInputEntryActivityからのforwarding Intentであれ、
        // legacy task restoreによる何らかのIntentであれ、通知は
        // pending storeの存在有無だけをtriggerにする）。
        notifyExternalInputAvailableIfPending()
        nativeObservability.logEvent(
            "activity_lifecycle",
            mapOf("stage" to "on_new_intent_exit", "activityInstanceId" to activityInstanceId),
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        nativeObservability.logEvent(
            "flutter_engine_lifecycle",
            mapOf(
                "stage" to "configure_flutter_engine_enter",
                "activityInstanceId" to activityInstanceId,
                "flutterEngineInstanceId" to System.identityHashCode(flutterEngine),
            ),
        )
        // 既存のGeneratedPluginRegistrant経由のplugin登録
        // （flutter_sharing_intent含む）を必ず先に完了させる。
        super.configureFlutterEngine(flutterEngine)

        // No.94 Share Event Architecture専用の統合MethodChannel。
        val externalInputChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EXTERNAL_INPUT_METHOD_CHANNEL,
        )
        externalInputMethodChannel = externalInputChannel
        externalInputChannel.setMethodCallHandler { call, result ->
            if (call.method == "pullPendingExternalInput") {
                nativeObservability.logEvent(
                    "external_input_bridge",
                    mapOf("stage" to "pull_requested"),
                )
                // 本文(+source/kind)をDartへ渡す唯一の消費経路。読み取りと
                // 同時にclearする（このメソッドだけが本文を返す。
                // externalInputAvailable通知は本文を一切運ばない）。
                val envelope = ExternalInputPendingStore.pull()
                if (envelope != null) {
                    result.success(
                        mapOf(
                            "source" to envelope.source,
                            "kind" to envelope.kind,
                            "text" to envelope.text,
                        ),
                    )
                } else {
                    result.success(null)
                }
                nativeObservability.logEvent(
                    "external_input_bridge",
                    mapOf("stage" to "pull_returned", "present" to (envelope != null)),
                )
            } else {
                result.notImplemented()
            }
        }

        // Persistent Share Observability Phase 1専用のMethodChannel。
        // 診断情報(native persistent share log snapshot)取得専用であり、
        // external input deliveryには一切使用しない。
        val observabilityChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NATIVE_SHARE_OBSERVABILITY_METHOD_CHANNEL,
        )
        observabilityChannel.setMethodCallHandler { call, result ->
            if (call.method == "getNativeShareLogSnapshot") {
                nativeObservability.getSnapshotAsync { snapshot ->
                    // MethodChannel.Resultはmain(platform) threadから呼ぶ前提。
                    mainHandler.post {
                        try {
                            result.success(snapshot)
                        } catch (t: Throwable) {
                            // Activity/engineが既にdetachしている等で応答不可の
                            // 場合は無視する（診断機能自体の失敗でアプリを
                            // 落とさない）。
                        }
                    }
                }
            } else {
                result.notImplemented()
            }
        }

        // Dart isolateが既に生存していた場合（cached engine）、Dart側の
        // 通知handlerは既に登録済みの可能性が高いため、ここでも通知を
        // 試みる。genuine cold startの場合はDart側handlerが未登録のため
        // 通知は届かないが、Dart起動後のpull fallbackで回収される。
        notifyExternalInputAvailableIfPending()

        nativeObservability.logEvent(
            "flutter_engine_lifecycle",
            mapOf(
                "stage" to "configure_flutter_engine_exit",
                "activityInstanceId" to activityInstanceId,
                "flutterEngineInstanceId" to System.identityHashCode(flutterEngine),
            ),
        )
    }

    // pendingが存在することをDartへ「通知」するだけのfire-and-forget
    // 呼び出し。本文は一切運ばない。本文をDartへ渡す経路は
    // `pullPendingExternalInput`の応答のみであるため、この通知が何回・
    // どのタイミングで届いても（またはDart側handler未登録で届かなくても）、
    // 二重に本文が渡ることは構造的に起こらない。
    private fun notifyExternalInputAvailableIfPending() {
        val channel = externalInputMethodChannel
        if (channel == null) {
            nativeObservability.logEvent(
                "external_input_bridge",
                mapOf("stage" to "notification_skipped", "reason" to "channel_not_ready"),
            )
            return
        }
        if (!ExternalInputPendingStore.hasPending()) {
            nativeObservability.logEvent(
                "external_input_bridge",
                mapOf("stage" to "notification_skipped", "reason" to "no_pending"),
            )
            return
        }
        nativeObservability.logEvent(
            "external_input_bridge",
            mapOf("stage" to "notification_attempted"),
        )
        channel.invokeMethod("externalInputAvailable", null)
    }

    companion object {
        private const val EXTERNAL_INPUT_METHOD_CHANNEL =
            "com.example.readaloud_app/external_input"
        private const val NATIVE_SHARE_OBSERVABILITY_METHOD_CHANNEL =
            "com.example.readaloud_app/native_share_observability"
    }
}
