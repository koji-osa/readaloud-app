package com.example.readaloud_app

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.webkit.URLUtil
import java.security.MessageDigest

/**
 * No.94 Share Event Architecture（Architecture Z）。
 * `ACTION_SEND`(text/plain)および`ACTION_PROCESS_TEXT`(text/plain)の
 * **唯一の**外部ingress。詳細設計は
 * `No94_ShareEvent_Architecture_Design_20260908_v3.md`、
 * `_v3_addendum.md`、および
 * `No94_ExternalInput_ArchitectureZ_PreCommit_Review_20260908_v2.md`
 * （PR #30 Intent observability lineageの本Activityへの移植）参照。
 *
 * plain [Activity]（[io.flutter.embedding.android.FlutterActivity]を
 * 継承しない）であり、FlutterEngineへは一切attachしない。capture後は
 * [ExternalInputPendingStore]へ書き込み、[MainActivity]を明示的に
 * 前面化（forwarding）したうえで即座に[finish]する。可視UIを一切
 * 持たない（`AndroidManifest.xml`の`Theme.Translucent.NoTitleBar`・
 * `noHistory`・`excludeFromRecents`参照）。
 *
 * 【Freshness / Stale-Safety Model（v3設計書§4、単一根拠にしない）】
 * A. `ACTION_SEND`/`ACTION_PROCESS_TEXT`の外部intent-filterは
 *    [MainActivity]から完全に除去済み（このActivityのみがこれらを
 *    受ける）。
 * B. raw external payloadを読むコードはこのActivityにのみ存在する。
 * C. [MainActivity]はlegacy Intentを（task復元等で）受け取っても
 *    payloadを一切captureしない（[MainActivity]参照）。
 * D. このActivityはephemeral（UI無し、即finish）。
 * E. `savedInstanceState != null`（このinstance自身の再生成）の
 *    場合は、captureもforwardingも行わない（Android基本契約に基づく
 *    first-creation gate、[onCreate]参照）。
 * F. 期待するaction/type、`FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`
 *    gate、非空payload gateを通過したfirst-creation invocationだけ
 *    captureする。
 * G. capture成功時のみ[MainActivity]を明示的にwakeし、いずれの場合も
 *    このActivity自身は即[finish]する。
 * H. `noHistory`/`excludeFromRecents`はfreshness proofの根拠では
 *    なく、UX/back-stack hygiene（Recents非露出・UI flash防止）として
 *    用いる。
 *
 * stale-safetyはA〜Hの複合構造で成立する。content fingerprint等の
 * 判定は一切行わない（同一contentでも常にfreshとして扱う、P-01/P-02）。
 *
 * 【PR #30 Intent Observability lineageの移植（ChatGPT precommit review
 * v2 Fix 1）】
 * raw external Intentを実際に所有するのは（Architecture Zにより）この
 * Activityのみとなったため、旧`MainActivity.logShareIntentIfPresent`/
 * `persistShareIntentEvent`が持っていたprivacy-safe Intent metadata
 * observability（action/MIME type/flags/`FLAG_ACTIVITY_LAUNCHED_
 * FROM_HISTORY`/`EXTRA_TEXT`・`EXTRA_PROCESS_TEXT`のpresence・
 * charCount・trimmed charCount・SHA-256/ClipData presence・itemCount・
 * 先頭[MAX_LOGGED_CLIP_ITEMS]件のitem metadata）を、[logShareIntentIfPresent]・
 * [persistShareIntentEvent]としてこのActivityへ移植する。既存の
 * `native_share_intent_received`（Logcat）・`native_share_intent_persisted`
 * （[NativeShareObservability]永続ログ）というイベント名はそのまま
 * 維持し（既存解析lineageとの互換性）、`component`フィールド
 * （[COMPONENT_NAME]）と新しい`stage`値（[STAGE_ON_CREATE]）だけを
 * 追加することで、「旧MainActivity経路のイベント」と「新
 * ExternalInputEntryActivity経路のイベント」を事後解析で区別できる
 * ようにする。[onCreate]の最初（`super.onCreate()`直後、
 * `savedInstanceState`分岐より前）で、capture成否に関わらず常に
 * 呼び出す（旧MainActivityが`captureXxxIfPresent`より前に無条件で
 * これらを呼んでいたのと同じ方針）。
 *
 * この移植はcapture/forwarding/finishという既存のcore delivery pathを
 * 一切変更しない（観測点の追加のみ）。observability処理自身の失敗が
 * delivery失敗へ波及しないよう、[logShareIntentIfPresent]・
 * [persistShareIntentEvent]は共に独立してtry/catchで囲む（旧
 * MainActivityの同名関数と同じ防御方針）。
 *
 * 【ACTION_PROCESS_TEXT】
 * 選択テキストは常にkind=text固定（URL昇格しない、既存
 * `ProcessTextHandler`と同じ方針。「選択したものを聴く」操作のため
 * Web Importへは送らない）。[setResult]は一切呼ばない
 * （`EXTRA_PROCESS_TEXT_READONLY`の値に関わらず一貫してread-only
 * consumer。Android公式`ACTION_PROCESS_TEXT`contract上`setResult()`は
 * 完全にoptionalであることを確認済み）。
 *
 * 【Forwarding】
 * `Intent(this, MainActivity::class.java)`という、action文字列を
 * 持たないexplicit Intentへ`FLAG_ACTIVITY_NEW_TASK`のみを付与して
 * `startActivity()`する。raw payloadは一切含めない（payloadは
 * [ExternalInputPendingStore]経由のみ）。`FLAG_ACTIVITY_CLEAR_TOP`は
 * ユーザーが現在使用中の画面（Quick Listen/AddScreen等）を意図せず
 * 破棄してしまうため、`FLAG_ACTIVITY_REORDER_TO_FRONT`は
 * [MainActivity]自体の`singleTask` launchModeと意味が重複するため、
 * いずれも使わない。
 */
class ExternalInputEntryActivity : Activity() {

    private val nativeObservability: NativeShareObservability
        get() = NativeShareObservability.getInstance(applicationContext)

    // Persistent Share Observability: このActivity instanceを識別するID
    // （本文を含まない、process内identity）。standard launchModeのため
    // 1回の外部イベント＝1 instanceとなり、このIDで個々のイベントの
    // ログ行を相関付けできる（旧MainActivityのactivityInstanceIdと同じ
    // 考え方）。
    private val activityInstanceId = System.identityHashCode(this)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // PR #30 Intent observability lineage（ChatGPT precommit review v2
        // Fix 1）: raw Intentを実際に持つのはこのActivityだけなので、
        // capture成否に関わらず、まずprivacy-safeなIntent metadataを
        // 記録する（class doc参照）。
        logShareIntentIfPresent(intent, stage = STAGE_ON_CREATE)
        persistShareIntentEvent(intent, stage = STAGE_ON_CREATE)

        if (savedInstanceState != null) {
            // このinstance自身の再生成（configuration change等）。
            // fresh external eventではないため、captureもforwardingも
            // 行わない（class docの freshness model E 参照）。
            nativeObservability.logEvent(
                "external_input_bridge",
                mapOf(
                    "stage" to "capture_skipped",
                    "reason" to "recreated_instance",
                    "activityInstanceId" to activityInstanceId,
                ),
            )
            finish()
            return
        }

        val captured = captureIfValid(intent)
        if (captured) {
            forwardToMainActivity()
        }
        finish()
    }

    private fun captureIfValid(intent: Intent?): Boolean {
        nativeObservability.logEvent(
            "external_input_bridge",
            mapOf("stage" to "capture_attempted", "activityInstanceId" to activityInstanceId),
        )
        if (intent == null) {
            nativeObservability.logEvent(
                "external_input_bridge",
                mapOf(
                    "stage" to "capture_skipped",
                    "reason" to "null_intent",
                    "activityInstanceId" to activityInstanceId,
                ),
            )
            return false
        }
        if ((intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) {
            // 履歴・task復元経由で古いIntentが再送されるケースを無視する
            // （PROCESS_TEXTの既存FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY
            // Gateと同じ方針。このActivity自身はnoHistory+
            // excludeFromRecentsのためこの経路は理論上稀だが、
            // 防御的に維持する）。
            nativeObservability.logEvent(
                "external_input_bridge",
                mapOf(
                    "stage" to "capture_skipped",
                    "reason" to "launched_from_history",
                    "activityInstanceId" to activityInstanceId,
                ),
            )
            return false
        }

        return when (intent.action) {
            Intent.ACTION_SEND -> captureActionSend(intent)
            Intent.ACTION_PROCESS_TEXT -> captureProcessText(intent)
            else -> {
                nativeObservability.logEvent(
                    "external_input_bridge",
                    mapOf(
                        "stage" to "capture_skipped",
                        "reason" to "wrong_action",
                        "activityInstanceId" to activityInstanceId,
                    ),
                )
                false
            }
        }
    }

    private fun captureActionSend(intent: Intent): Boolean {
        if (intent.type?.startsWith("text") != true) {
            nativeObservability.logEvent(
                "external_input_bridge",
                mapOf(
                    "stage" to "capture_skipped",
                    "reason" to "wrong_type",
                    "source" to SOURCE_ACTION_SEND,
                    "activityInstanceId" to activityInstanceId,
                ),
            )
            return false
        }
        // flutter_sharing_intent(getSharingText())と同じくEXTRA_TEXTのみを
        // 情報源とする（ClipDataへはフォールバックしない）。EXTRA_TEXTは
        // CharSequence仕様のため、getCharSequenceExtra()で取得する。
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        if (text.isNullOrEmpty()) {
            nativeObservability.logEvent(
                "external_input_bridge",
                mapOf(
                    "stage" to "capture_skipped",
                    "reason" to "missing_payload",
                    "source" to SOURCE_ACTION_SEND,
                    "activityInstanceId" to activityInstanceId,
                ),
            )
            return false
        }
        // 既存flutter_sharing_intent(getTypeForTextAndUrl())と同じ
        // URLUtil.isValidUrlでURL/textを判定し、意味を揃える。
        val kind = if (URLUtil.isValidUrl(text)) KIND_URL else KIND_TEXT
        capture(SOURCE_ACTION_SEND, kind, text)
        return true
    }

    private fun captureProcessText(intent: Intent): Boolean {
        if (intent.type?.startsWith("text") != true) {
            nativeObservability.logEvent(
                "external_input_bridge",
                mapOf(
                    "stage" to "capture_skipped",
                    "reason" to "wrong_type",
                    "source" to SOURCE_PROCESS_TEXT,
                    "activityInstanceId" to activityInstanceId,
                ),
            )
            return false
        }
        val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
        if (text.isNullOrEmpty()) {
            nativeObservability.logEvent(
                "external_input_bridge",
                mapOf(
                    "stage" to "capture_skipped",
                    "reason" to "missing_payload",
                    "source" to SOURCE_PROCESS_TEXT,
                    "activityInstanceId" to activityInstanceId,
                ),
            )
            return false
        }
        // 選択テキストは常にkind=text固定（URL昇格しない。class doc参照）。
        capture(SOURCE_PROCESS_TEXT, KIND_TEXT, text)
        // ReadAloudは読み取り専用の受け手であり、setResult()は
        // EXTRA_PROCESS_TEXT_READONLYの値に関わらず一切呼ばない
        // （class doc「ACTION_PROCESS_TEXT」参照）。
        return true
    }

    private fun capture(source: String, kind: String, text: String) {
        ExternalInputPendingStore.capture(
            ExternalInputPendingStore.Envelope(source = source, kind = kind, text = text),
        )
        nativeObservability.logEvent(
            "external_input_bridge",
            mapOf(
                "stage" to "captured",
                "source" to source,
                "kind" to kind,
                "charCount" to text.length,
                "textHash" to sha256Hex(text),
                "activityInstanceId" to activityInstanceId,
            ),
        )
        Log.i(TAG, "external_input captured source=$source kind=$kind charCount=${text.length}")
    }

    private fun forwardToMainActivity() {
        val forwardIntent = Intent(this, MainActivity::class.java)
        forwardIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
        startActivity(forwardIntent)
    }

    /**
     * PR #30 Intent observability lineage: 旧`MainActivity.
     * logShareIntentIfPresent`と同一のprivacy-safe metadata・同一の
     * イベント名（`native_share_intent_received`）をLogcatへ記録する
     * （class doc参照）。`component`/`stage`フィールドで新経路である
     * ことを明示する。本文（EXTRA_TEXT/EXTRA_PROCESS_TEXT/ClipData text
     * item自体）は一切記録しない（count/SHA-256のみ）。
     */
    private fun logShareIntentIfPresent(intent: Intent?, stage: String) {
        try {
            if (intent == null) return
            val line = StringBuilder("event=native_share_intent_received")
            line.append(" component=").append(COMPONENT_NAME)
            line.append(" activityInstanceId=").append(activityInstanceId)
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
            // Observability専用コード自身が原因でアプリを落とす、または
            // capture/forwarding/finishのcore delivery pathを止めることは
            // 絶対に避ける。
            Log.w(TAG, "native_share_intent_received logging failed: ${t.javaClass.name}")
        }
    }

    /**
     * PR #30 Intent observability lineage: 旧`MainActivity.
     * persistShareIntentEvent`と同等以上のprivacy-safe metadataを、
     * Logcatとは独立して[NativeShareObservability]永続ログへも
     * 同一イベント名（`native_share_intent_persisted`）で記録する
     * （class doc参照）。[logShareIntentIfPresent]とは独立してtry/catchで
     * 囲み、observability処理自身の失敗がcore delivery pathへ波及しない
     * ようにする。
     */
    private fun persistShareIntentEvent(intent: Intent?, stage: String) {
        try {
            if (intent == null) return
            val fields = LinkedHashMap<String, Any?>()
            fields["component"] = COMPONENT_NAME
            fields["activityInstanceId"] = activityInstanceId
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
        private const val SOURCE_ACTION_SEND = "action_send"
        private const val SOURCE_PROCESS_TEXT = "process_text"
        private const val KIND_TEXT = "text"
        private const val KIND_URL = "url"

        // PR #30 Intent observability lineage: 旧MainActivity経路のイベント
        // と新ExternalInputEntryActivity経路のイベントを事後解析で区別する
        // ための識別子。
        private const val COMPONENT_NAME = "ExternalInputEntryActivity"
        private const val STAGE_ON_CREATE = "external_input_entry_on_create"
    }
}
