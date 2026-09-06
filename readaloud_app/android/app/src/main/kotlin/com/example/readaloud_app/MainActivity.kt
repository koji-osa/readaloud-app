package com.example.readaloud_app

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

/**
 * No.94 Observability専用の最小限のフック、選択テキスト→ReadAloud
 * (ACTION_PROCESS_TEXT)の受け口、およびPersistent Share Observability
 * Phase 1のnative側イベント発生源。
 *
 * flutter_sharing_intentプラグイン(FlutterSharingIntentPlugin.onAttachedToActivity /
 * onNewIntent)がIntentを処理する前に、Activityが実際に受け取ったIntentの
 * privacy-safeなmetadata（本文は含まない：action/type/flags/EXTRA_TEXTの
 * 長さ・SHA-256等）だけをLogcatへ記録する。
 *
 * super.onCreate()/super.onNewIntent()は必ず呼び、Intentオブジェクト自体は
 * 一切書き換えない。既存のActivity/プラグイン初期化順序・Intent処理順序は
 * 変更しない（Observability only）。ログ処理自体が失敗してもアプリの起動や
 * Intent処理を止めないよう、必ずtry/catchで囲み例外を握りつぶす。
 *
 * 【trimmed hashの扱いについて】KotlinのString.trim()とDart側String.trim()が
 * 完全に同一のUnicode正規化仕様であることは保証していない。そのため
 * native/plugin境界の比較はextraTextHash/clipItemNTextHash（trim前のraw
 * hash）をprimary identityとして使うこと。extraTextTrimmedHash等のtrimmed
 * hashは補助情報（native/Dartのtrim実装差を切り分けたい場合の参考値）に
 * とどめ、post-trim境界の比較はDart側(ShareFingerprint)のtrimmed hash同士
 * で行う。
 *
 * 【ACTION_PROCESS_TEXTについて（選択テキスト→ReadAloud MVP）】
 * Android標準の「テキスト選択メニュー」から届くACTION_PROCESS_TEXTは、
 * flutter_sharing_intentプラグイン本体では一切処理されない
 * （FlutterSharingIntentPlugin.handleIntent()はACTION_SEND/SEND_MULTIPLE/
 * VIEW/WEB_SEARCHのみに反応し、それ以外のactionは無条件で無視される）。
 * plugin本体を改変せずにこの経路をサポートするため、ReadAloud独自の
 * MethodChannel([PROCESS_TEXT_METHOD_CHANNEL])をconfigureFlutterEngine()で
 * 追加し、Dart側(ProcessTextHandler)へ選択テキストを橋渡しする。
 * Intent.EXTRA_PROCESS_TEXTはEXTRA_TEXT同様CharSequence仕様のため、
 * getCharSequenceExtra()で取得する。
 *
 * 【重要: Activity cold start ≠ Dart cold start】
 * ReadAloudはaudio_service(0.18.18)を使用しており、AudioServiceActivityは
 * AudioServicePlugin.getFlutterEngine()からcached/shared FlutterEngineを
 * 取得する。そのため`onCreate()`が呼ばれても、Dartの`main()`/
 * `AppEntryPoint.initState()`が再実行されるとは限らない
 * （Activityだけが再生成され、Dart isolateとwidget treeの状態は
 * そのまま生き続けるケースがある）。「ActivityのonCreateだからDartも
 * cold」という前提を置くと、cached engineでDartが既に生存している場合に
 * 選択テキストを取りこぼす。
 *
 * 【単一消費経路（ChatGPT re-review v2対応）】
 * 当初はnative→Dartのpush(`deliverProcessText`)が選択テキスト本文
 * そのものを運んでいたが、pushのack応答でpending slotがクリアされる前に
 * Dart側のstartup pull(`pullPendingProcessText`)が同じ本文を取得できる
 * race（同一PROCESS_TEXTの二重delivery）があったため設計を変更した。
 *
 * 現在は、native→Dartのpushは`processTextAvailable`という**本文を含まない
 * 通知**のみに変更している。選択テキスト本文をDartへ渡す経路は
 * `pullPendingProcessText()`の応答**だけ**であり、native側はこの呼び出しで
 * のみ`pendingProcessText`を読み取ると同時にクリアする（atomic consume）。
 * 通知契機（`onCreate`/`onNewIntent`/`configureFlutterEngine`のたびに
 * `notifyProcessTextAvailableIfPending()`を呼ぶ）は、Dart側に「pullしに
 * 来てよい」と伝えるだけのトリガーであり、応答も追跡しない
 * （fire-and-forget）。Dart側がいつpullしても、実際に本文を取得できるのは
 * 高々1回だけであり、二重配信は構造的に起こらない。
 *
 * 【FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY Gate】
 * 履歴・task復元経由で古いPROCESS_TEXT Intentが再処理され、以前選択した
 * 文章が再びQuick Listenへ入ることを防ぐため、`captureProcessTextIfPresent()`
 * はこのフラグが立っている場合captureをskipする。flutter_sharing_intent
 * (`FlutterSharingIntentPlugin.handleIntent()`)も同じフラグでIntent処理を
 * skipしており、No.94で確立したIntent freshness方針と揃えている。
 *
 * ReadAloudは選択テキストを読み上げるだけの読み取り専用の受け手であり、
 * 選択元アプリへ編集結果を返す用途ではないため、Activity.setResult()は
 * 一切呼ばない。Intent.EXTRA_PROCESS_TEXT_READONLYの値に関わらずこの方針は
 * 変わらない（setResult()を呼ばずにfinish/pause相当になった場合、選択元は
 * RESULT_CANCELED相当として扱い元のテキストをそのまま維持するため、
 * READONLYフラグの値ごとの分岐は不要）。
 *
 * 【Persistent Share Observability Phase 1】
 * No.94（ACTION_SEND間欠配信消失、root cause未確定）の次回自然再発時に、
 * ADB/Logcatをリアルタイム接続していなくても事後のログexportだけで
 * native→Dart境界を切り分けられるようにするため、[NativeShareObservability]
 * （Dart DebugLoggerとは独立したnative側永続ロガー）へ、Activity/
 * FlutterEngineのlifecycle・Intent受信・PROCESS_TEXT bridgeの状態を
 * privacy-safeに記録する。既存のLogcat出力(`logShareIntentIfPresent`)や
 * ACTION_SEND/PROCESS_TEXTの処理順序・delivery方式は一切変更しない
 * （観測点の追加のみ）。
 */
class MainActivity : AudioServiceActivity() {
    // ACTION_PROCESS_TEXTで受け取った選択テキストの唯一の情報源。
    // Dart側の`pullPendingProcessText`呼び出し（唯一の消費経路）で
    // 読み取りと同時にクリアする（atomic consume、一度きりの消費パターン）。
    @Volatile
    private var pendingProcessText: String? = null

    // configureFlutterEngine()のたびに再生成される（cached engineでも
    // Activity attachのたびに新しいMethodChannelインスタンスを作り直す。
    // Dart側のhandler登録自体はDart isolateの生存期間中1回のみで、
    // channel名が同じであれば新しいMethodChannelインスタンスからの
    // invokeMethod()も正しく届く）。
    private var processTextMethodChannel: MethodChannel? = null

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
        logShareIntentIfPresent(intent, stage = "on_create")
        persistShareIntentEvent(intent, stage = "on_create")
        captureProcessTextIfPresent(intent)
        // super.onCreate()の中でconfigureFlutterEngine()が呼ばれ、
        // processTextMethodChannelがセットされたうえで通知が試みられる
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
        logShareIntentIfPresent(intent, stage = "on_new_intent")
        persistShareIntentEvent(intent, stage = "on_new_intent")
        captureProcessTextIfPresent(intent)
        super.onNewIntent(intent)
        // onNewIntent()ではconfigureFlutterEngine()は再度呼ばれない
        // （Activity-engineの接続は既に確立済みのため）。そのためここで
        // 明示的に通知を試みる。
        notifyProcessTextAvailableIfPending()
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
        // 既存のGeneratedPluginRegistrant経由のplugin登録(flutter_sharing_intent
        // 含む)を必ず先に完了させる。plugin本体の初期化順序・挙動は変更しない。
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PROCESS_TEXT_METHOD_CHANNEL,
        )
        processTextMethodChannel = channel
        channel.setMethodCallHandler { call, result ->
            if (call.method == "pullPendingProcessText") {
                nativeObservability.logEvent(
                    "process_text_bridge",
                    mapOf("stage" to "pull_requested"),
                )
                // 選択テキスト本文をDartへ渡す唯一の消費経路。読み取りと
                // 同時にクリアする（このメソッドだけが本文を返す。
                // processTextAvailable通知は本文を一切運ばない）。
                val text = pendingProcessText
                result.success(text)
                pendingProcessText = null
                nativeObservability.logEvent(
                    "process_text_bridge",
                    mapOf("stage" to "pull_returned", "present" to (text != null)),
                )
            } else {
                result.notImplemented()
            }
        }

        // Persistent Share Observability Phase 1専用のMethodChannel。
        // 診断情報(native persistent share log snapshot)取得専用であり、
        // ACTION_SEND/PROCESS_TEXT deliveryには一切使用しない。
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
        notifyProcessTextAvailableIfPending()

        nativeObservability.logEvent(
            "flutter_engine_lifecycle",
            mapOf(
                "stage" to "configure_flutter_engine_exit",
                "activityInstanceId" to activityInstanceId,
                "flutterEngineInstanceId" to System.identityHashCode(flutterEngine),
            ),
        )
    }

    private fun captureProcessTextIfPresent(intent: Intent?) {
        try {
            nativeObservability.logEvent(
                "process_text_bridge",
                mapOf("stage" to "capture_attempted"),
            )
            if (intent == null || intent.action != Intent.ACTION_PROCESS_TEXT) {
                nativeObservability.logEvent(
                    "process_text_bridge",
                    mapOf("stage" to "capture_skipped", "reason" to "wrong_action"),
                )
                return
            }
            if ((intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) {
                // 履歴・task復元経由で古いPROCESS_TEXT Intentが再送される
                // ケースを無視する（class docの「FLAG_ACTIVITY_LAUNCHED_
                // FROM_HISTORY Gate」参照）。
                nativeObservability.logEvent(
                    "process_text_bridge",
                    mapOf(
                        "stage" to "capture_skipped",
                        "reason" to "launched_from_history",
                    ),
                )
                return
            }
            val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
            if (text == null) {
                nativeObservability.logEvent(
                    "process_text_bridge",
                    mapOf("stage" to "capture_skipped", "reason" to "missing_payload"),
                )
                return
            }
            pendingProcessText = text
            nativeObservability.logEvent(
                "process_text_bridge",
                mapOf("stage" to "captured", "charCount" to text.length),
            )
        } catch (t: Throwable) {
            // Observability/橋渡しコード自身が原因でIntent処理やアプリ起動を
            // 止めることは絶対に避ける。
            Log.w(TAG, "captureProcessTextIfPresent failed: ${t.javaClass.name}")
        }
    }

    // pendingProcessTextが存在することをDartへ「通知」するだけの
    // fire-and-forget呼び出し。本文は一切運ばない。選択テキスト本文を
    // Dartへ渡す経路は`pullPendingProcessText`の応答のみであるため、
    // この通知が何回・どのタイミングで届いても（またはDart側handler未登録で
    // 届かなくても）、二重に本文が渡ることは構造的に起こらない。
    private fun notifyProcessTextAvailableIfPending() {
        val channel = processTextMethodChannel
        if (channel == null) {
            nativeObservability.logEvent(
                "process_text_bridge",
                mapOf("stage" to "notification_skipped", "reason" to "channel_not_ready"),
            )
            return
        }
        if (pendingProcessText == null) {
            nativeObservability.logEvent(
                "process_text_bridge",
                mapOf("stage" to "notification_skipped", "reason" to "no_pending"),
            )
            return
        }
        nativeObservability.logEvent(
            "process_text_bridge",
            mapOf("stage" to "notification_attempted"),
        )
        channel.invokeMethod("processTextAvailable", null)
    }

    private fun logShareIntentIfPresent(intent: Intent?, stage: String) {
        try {
            if (intent == null) return
            val line = StringBuilder("event=native_share_intent_received")
            line.append(" stage=").append(stage)
            line.append(" action=").append(intent.action ?: "null")
            line.append(" type=").append(intent.type ?: "null")
            line.append(" flags=").append(intent.flags)
            line.append(" launchedFromHistory=")
                .append((intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0)

            // Intent.EXTRA_TEXT is documented as CharSequence (may be a styled/
            // spanned CharSequence, not necessarily a plain String). Reading it
            // via getStringExtra() would silently miss non-String CharSequence
            // payloads and misreport hasExtraText=false, so read it as
            // CharSequence first and convert to String only for hashing/length.
            val extraText = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            line.append(" hasExtraText=").append(extraText != null)
            if (extraText != null) {
                val trimmed = extraText.trim()
                line.append(" extraTextCharCount=").append(extraText.length)
                line.append(" extraTextTrimmedCharCount=").append(trimmed.length)
                line.append(" extraTextHash=").append(sha256Hex(extraText))
                line.append(" extraTextTrimmedHash=").append(sha256Hex(trimmed))
            }

            // ACTION_PROCESS_TEXT(テキスト選択メニュー経由)の選択テキスト。
            // EXTRA_TEXTと同じCharSequence仕様・同じprivacy-safe metadataのみ記録。
            val extraProcessText =
                intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
            line.append(" hasExtraProcessText=").append(extraProcessText != null)
            if (extraProcessText != null) {
                val trimmedProcessText = extraProcessText.trim()
                line.append(" extraProcessTextCharCount=").append(extraProcessText.length)
                line.append(" extraProcessTextTrimmedCharCount=")
                    .append(trimmedProcessText.length)
                line.append(" extraProcessTextHash=").append(sha256Hex(extraProcessText))
                line.append(" extraProcessTextTrimmedHash=")
                    .append(sha256Hex(trimmedProcessText))
            }

            val clipData = intent.clipData
            line.append(" hasClipData=").append(clipData != null)
            if (clipData != null) {
                val itemCount = clipData.itemCount
                line.append(" clipDataItemCount=").append(itemCount)
                // 大量item時にログが肥大化しないよう、先頭MAX_LOGGED_CLIP_ITEMS件
                // のみprivacy-safe metadataを記録する（総件数はclipDataItemCountで
                // 常に分かる）。
                val limit = minOf(itemCount, MAX_LOGGED_CLIP_ITEMS)
                for (i in 0 until limit) {
                    val item = clipData.getItemAt(i)
                    val text = item.text?.toString()
                    line.append(" clipItem").append(i).append("TextPresent=")
                        .append(text != null)
                    if (text != null) {
                        val trimmedText = text.trim()
                        line.append(" clipItem").append(i).append("TextCharCount=")
                            .append(text.length)
                        line.append(" clipItem").append(i).append("TextTrimmedCharCount=")
                            .append(trimmedText.length)
                        line.append(" clipItem").append(i).append("TextHash=")
                            .append(sha256Hex(text))
                        line.append(" clipItem").append(i).append("TextTrimmedHash=")
                            .append(sha256Hex(trimmedText))
                    }
                    line.append(" clipItem").append(i).append("UriPresent=")
                        .append(item.uri != null)
                }
            }

            line.append(" epochMs=").append(System.currentTimeMillis())
            Log.i(TAG, line.toString())
        } catch (t: Throwable) {
            // Observability専用コード自身が原因でアプリを落とすことは絶対に避ける。
            Log.w(TAG, "native_share_intent_received logging failed: ${t.javaClass.name}")
        }
    }

    /**
     * Persistent Share Observability Phase 1: [logShareIntentIfPresent]と
     * 同等以上のprivacy-safe情報を、Logcatとは独立してnative永続ログへも
     * 残す。[logShareIntentIfPresent]自体は一切変更せず、既存のLogcat出力
     * フォーマット・内容を完全に保つ（既存observabilityの回帰防止）。
     */
    private fun persistShareIntentEvent(intent: Intent?, stage: String) {
        try {
            if (intent == null) return
            val fields = LinkedHashMap<String, Any?>()
            fields["stage"] = stage
            fields["action"] = intent.action ?: "null"
            fields["type"] = intent.type ?: "null"
            fields["flags"] = intent.flags
            fields["launchedFromHistory"] =
                (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0

            val extraText = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            fields["hasExtraText"] = extraText != null
            if (extraText != null) {
                val trimmed = extraText.trim()
                fields["extraTextCharCount"] = extraText.length
                fields["extraTextTrimmedCharCount"] = trimmed.length
                fields["extraTextHash"] = sha256Hex(extraText)
                fields["extraTextTrimmedHash"] = sha256Hex(trimmed)
            }

            val extraProcessText =
                intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
            fields["hasExtraProcessText"] = extraProcessText != null
            if (extraProcessText != null) {
                val trimmedProcessText = extraProcessText.trim()
                fields["extraProcessTextCharCount"] = extraProcessText.length
                fields["extraProcessTextTrimmedCharCount"] = trimmedProcessText.length
                fields["extraProcessTextHash"] = sha256Hex(extraProcessText)
                fields["extraProcessTextTrimmedHash"] = sha256Hex(trimmedProcessText)
            }

            val clipData = intent.clipData
            fields["hasClipData"] = clipData != null
            if (clipData != null) {
                val itemCount = clipData.itemCount
                fields["clipDataItemCount"] = itemCount
                val limit = minOf(itemCount, MAX_LOGGED_CLIP_ITEMS)
                for (i in 0 until limit) {
                    val item = clipData.getItemAt(i)
                    val text = item.text?.toString()
                    fields["clipItem${i}TextPresent"] = text != null
                    if (text != null) {
                        val trimmedText = text.trim()
                        fields["clipItem${i}TextCharCount"] = text.length
                        fields["clipItem${i}TextTrimmedCharCount"] = trimmedText.length
                        fields["clipItem${i}TextHash"] = sha256Hex(text)
                        fields["clipItem${i}TextTrimmedHash"] = sha256Hex(trimmedText)
                    }
                    fields["clipItem${i}UriPresent"] = item.uri != null
                    fields["clipItem${i}IntentPresent"] = item.intent != null
                    fields["clipItem${i}HtmlTextPresent"] = item.htmlText != null
                }
            }

            nativeObservability.logEvent("native_share_intent_persisted", fields)
        } catch (t: Throwable) {
            Log.w(TAG, "persistShareIntentEvent failed: ${t.javaClass.name}")
        }
    }

    private fun sha256Hex(value: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }

    companion object {
        private const val TAG = "ReadAloudShareObs"
        private const val MAX_LOGGED_CLIP_ITEMS = 3
        private const val PROCESS_TEXT_METHOD_CHANNEL =
            "com.example.readaloud_app/process_text"
        private const val NATIVE_SHARE_OBSERVABILITY_METHOD_CHANNEL =
            "com.example.readaloud_app/native_share_observability"
    }
}
