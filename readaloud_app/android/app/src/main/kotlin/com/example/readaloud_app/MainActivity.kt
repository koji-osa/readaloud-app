package com.example.readaloud_app

import android.content.Intent
import android.os.Bundle
import android.util.Log
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

/**
 * No.94 Observability専用の最小限のフック、および選択テキスト→ReadAloud
 * (ACTION_PROCESS_TEXT)の受け口。
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

    override fun onCreate(savedInstanceState: Bundle?) {
        logShareIntentIfPresent(intent, stage = "on_create")
        captureProcessTextIfPresent(intent)
        // super.onCreate()の中でconfigureFlutterEngine()が呼ばれ、
        // processTextMethodChannelがセットされたうえで通知が試みられる
        // （cached engineでDartが既に生存していれば、ここで即座に届く）。
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        logShareIntentIfPresent(intent, stage = "on_new_intent")
        captureProcessTextIfPresent(intent)
        super.onNewIntent(intent)
        // onNewIntent()ではconfigureFlutterEngine()は再度呼ばれない
        // （Activity-engineの接続は既に確立済みのため）。そのためここで
        // 明示的に通知を試みる。
        notifyProcessTextAvailableIfPending()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
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
                // 選択テキスト本文をDartへ渡す唯一の消費経路。読み取りと
                // 同時にクリアする（このメソッドだけが本文を返す。
                // processTextAvailable通知は本文を一切運ばない）。
                result.success(pendingProcessText)
                pendingProcessText = null
            } else {
                result.notImplemented()
            }
        }

        // Dart isolateが既に生存していた場合（cached engine）、Dart側の
        // 通知handlerは既に登録済みの可能性が高いため、ここでも通知を
        // 試みる。genuine cold startの場合はDart側handlerが未登録のため
        // 通知は届かないが、Dart起動後のpull fallbackで回収される。
        notifyProcessTextAvailableIfPending()
    }

    private fun captureProcessTextIfPresent(intent: Intent?) {
        try {
            if (intent == null || intent.action != Intent.ACTION_PROCESS_TEXT) return
            if ((intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) {
                // 履歴・task復元経由で古いPROCESS_TEXT Intentが再送される
                // ケースを無視する（class docの「FLAG_ACTIVITY_LAUNCHED_
                // FROM_HISTORY Gate」参照）。
                return
            }
            val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
                ?: return
            pendingProcessText = text
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
        val channel = processTextMethodChannel ?: return
        if (pendingProcessText == null) return
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
    }
}
