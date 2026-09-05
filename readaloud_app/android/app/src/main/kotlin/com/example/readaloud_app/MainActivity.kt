package com.example.readaloud_app

import android.content.Intent
import android.os.Bundle
import android.util.Log
import com.ryanheise.audioservice.AudioServiceActivity
import java.security.MessageDigest

/**
 * No.94 Observability専用の最小限のフック。
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
 */
class MainActivity : AudioServiceActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        logShareIntentIfPresent(intent, stage = "on_create")
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        logShareIntentIfPresent(intent, stage = "on_new_intent")
        super.onNewIntent(intent)
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
    }
}
