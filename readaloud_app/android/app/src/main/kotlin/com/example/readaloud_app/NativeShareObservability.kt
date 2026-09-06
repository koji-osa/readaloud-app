package com.example.readaloud_app

import android.content.Context
import android.os.Process
import android.os.SystemClock
import java.io.File
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/**
 * No.94 Persistent Share Observability専用の、Dart DebugLoggerとは独立した
 * native側永続ロガー。
 *
 * 【目的】
 * Android IntentがMainActivityへ到達した事実を、Dart isolate/FlutterEngineの
 * 状態に一切依存せず記録し、process再起動を跨いで残すことで、次回のNo.94
 * 自然再発時に「nativeでは受信できていたか」を事後diagnosticとして確認
 * できるようにする（Observability only。root cause修正やIntent処理・
 * ACTION_SEND/PROCESS_TEXT delivery方式の変更は一切行わない）。
 *
 * 【Low perturbation】
 * すべてのファイルI/Oは単一のbackground executor(1スレッド)で直列化する。
 * [logEvent]はこのexecutorへ非同期投入するだけで即座にreturnするため、
 * Activity mainスレッド(onCreate/onNewIntent等)を一切ブロックしない。
 * [getSnapshotAsync]も同じexecutorへ投入するだけで、呼び出し元スレッドを
 * ブロックしない（結果はcallback経由で非同期に返る。同じexecutor上で
 * 順番に処理されるため、投入時点までのpending writeは自動的にflushされて
 * からsnapshotが読み取られる）。
 *
 * 【Bounded retention】
 * current/backupの2ファイルによるboundedなrolling方式（既定各256KB、
 * 合計最大512KB程度）。次に書き込むentry分のbyte数も考慮したうえで
 * currentが上限に達する前にbackupへrenameし、新しいcurrentを作る
 * （[rotate]参照）。delete/renameが失敗した場合（ファイルシステムの
 * 制約等）でも、無制限にcurrentへappendし続けることは絶対に避け、
 * 古いdiagnosticを失ってでもcurrentをtruncateしてboundを守る
 * fail-safeを備える（ChatGPT precommit review v2 Fix 2 要件A）。
 * アプリ起動のたびに消去せず、[Context.getFilesDir]配下
 * （キャッシュではなく永続領域）に保存するためprocess再起動を跨いで残る。
 * uninstallまたは「アプリデータの消去」でのみクリアされる。
 *
 * 【Per-event size bound / line integrity】
 * 1件のfield valueの文字数（[MAX_FIELD_VALUE_CHARS]）および1行
 * （1イベント）全体のbyte数（[MAX_LINE_BYTES]、[boundLine]）にも上限を
 * 設け、極端に長い単一valueや大量fieldだけでログを肥大化させない
 * （ChatGPT precommit review v2 Fix 2 要件B）。action/type等の
 * external inputに含まれうる`\n`/`\r`/`\t`は、実ログの改行や別イベント
 * として誤解釈されないよう[sanitizeFieldValue]でescapeする
 * （同 要件C。hash/bool/numeric等の通常値はこれらの文字を含まないため
 * 無変換のまま出力される）。
 *
 * 【Privacy-safe】
 * 本文・選択テキスト実体・clipboard内容実体・URL実体・title・URI実体・
 * ClipData text実体は絶対に書き込まない。呼び出し元([MainActivity])が
 * privacy-safeなfields(action名/MIME type/flags/bool/count/length/
 * SHA-256 fingerprint/lifecycle state/instance ID/process ID/timestamp等)
 * だけを渡す前提のヘルパーであり、本クラス自体は値の中身を検査しない
 * （検査・除外の責務は呼び出し元のfields構築側にある。Dart側DebugLoggerの
 * isForbiddenKeyに相当する仕組みは、native側ではfields構築を1箇所
 * [MainActivity]に集約することで担保する）。
 */
class NativeShareObservability private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val seqCounter = AtomicLong(0)

    // このprocess生存期間を識別するID。本文情報を含まない、process-localな
    // 識別のみが目的（複数のActivity再生成やFlutterEngine再アタッチをまたいで
    // 「同じprocess内で起きたことか」を事後判定できるようにする）。
    val processSessionId: String = UUID.randomUUID().toString()
    val pid: Int = Process.myPid()

    private val currentFile = File(appContext.filesDir, CURRENT_FILE_NAME)
    private val backupFile = File(appContext.filesDir, BACKUP_FILE_NAME)

    /**
     * 1件のイベントを記録する。呼び出し元スレッドをブロックしない
     * （executorへの投入のみ即座に完了する）。
     *
     * [fields]には本文相当の値を絶対に含めないこと（呼び出し元の責務）。
     */
    fun logEvent(name: String, fields: Map<String, Any?> = emptyMap()) {
        val seq = seqCounter.incrementAndGet()
        val rawLine = buildString {
            append("event=").append(sanitizeFieldValue(name))
            append(" seq=").append(seq)
            append(" processSessionId=").append(processSessionId)
            append(" pid=").append(pid)
            append(" epochMs=").append(System.currentTimeMillis())
            append(" elapsedRealtimeMs=").append(SystemClock.elapsedRealtime())
            for ((key, value) in fields) {
                append(' ').append(key).append('=').append(sanitizeFieldValue(value))
            }
        }
        val line = boundLine(rawLine)
        executor.execute {
            try {
                appendLineBounded(line)
            } catch (t: Throwable) {
                // persistent logger自身の失敗がアプリ動作へ波及することは
                // 絶対に避ける。
            }
        }
    }

    /**
     * ChatGPT precommit review v2 Fix 2 (要件C: line integrity):
     * field valueに含まれうる`\n`/`\r`/`\t`（およびbackslash自身）が実ログの
     * 改行や別イベントの開始として誤解釈されないようescapeし、
     * `key=value`をspace区切りで並べる既存format自体を壊さないよう
     * 生のspaceは`_`に正規化する。action/type等はexternal inputだが、
     * raw本文(EXTRA_TEXT/EXTRA_PROCESS_TEXT/URI等)を新たに保存する
     * 変更ではない（値の中身そのものを検査する責務は引き続き呼び出し元
     * [MainActivity]のfields構築側にある）。
     *
     * 同時に(要件B): 個々のfield valueの文字数にも[MAX_FIELD_VALUE_CHARS]の
     * 上限を設け、極端に長い単一valueだけでログを肥大化させない。
     * hash（64桁hex）/bool/numeric等の通常値はこの上限より十分短く、
     * escape対象の文字も含まないため、実質的に無変換のまま出力される。
     */
    private fun sanitizeFieldValue(value: Any?): String {
        val raw = value.toString()
        val limited = if (raw.length > MAX_FIELD_VALUE_CHARS) {
            raw.substring(0, MAX_FIELD_VALUE_CHARS) + "...TRUNCATED"
        } else {
            raw
        }
        val builder = StringBuilder(limited.length)
        for (c in limited) {
            when (c) {
                '\\' -> builder.append("\\\\")
                '\n' -> builder.append("\\n")
                '\r' -> builder.append("\\r")
                '\t' -> builder.append("\\t")
                ' ' -> builder.append('_')
                else -> builder.append(c)
            }
        }
        return builder.toString()
    }

    /**
     * ChatGPT precommit review v2 Fix 2 (要件B: per-event size bound):
     * 個々のfield valueをsanitize/truncateしても、field数が多い場合等に
     * イベント全体(1行)が肥大化しうるため、行全体のUTF-8 byte数にも
     * [MAX_LINE_BYTES]の上限を設ける。超過分は末尾を切り詰め、
     * truncateされたことが分かるmarkerを付与する。
     */
    private fun boundLine(line: String): String {
        val bytes = line.toByteArray(Charsets.UTF_8)
        if (bytes.size <= MAX_LINE_BYTES) return line
        val marker = " truncated=true"
        val markerBytes = marker.toByteArray(Charsets.UTF_8).size
        val keepBytes = (MAX_LINE_BYTES - markerBytes).coerceAtLeast(0)
        // UTF-8境界の途中で切れたmulti-byte文字が末尾に残っても、この
        // Stringコンストラクタは不正なbyte列を置換文字へ変換するため
        // 例外にはならない。
        val truncated = String(bytes, 0, keepBytes, Charsets.UTF_8)
        return truncated + marker
    }

    /**
     * ChatGPT precommit review v2 Fix 2 (要件A: hard bounded retention):
     * 次に書き込むentry([entryBytes])分のbyte数も考慮したうえで、
     * currentが上限に達する前にrotateする。rotate([rotate])が
     * delete/renameの失敗等で機能しなかった場合でも、currentへの
     * 無制限appendだけは絶対に避け、古いdiagnosticを失ってでも
     * currentをtruncateしてboundを守るfail-safeを備える。
     */
    private fun appendLineBounded(line: String) {
        try {
            val entryBytes = (line + "\n").toByteArray(Charsets.UTF_8)
            if (!currentFile.exists()) {
                currentFile.createNewFile()
            }
            if (currentFile.length() + entryBytes.size > MAX_FILE_BYTES) {
                rotate()
            }
            // rotate()がrename/delete失敗等で機能しなかった場合でも、
            // 「currentへの無制限append」だけは必ず防ぐ(fail-safe。
            // 古いdiagnosticを失ってもboundを守ることを優先する)。
            if (currentFile.length() + entryBytes.size > MAX_FILE_BYTES) {
                currentFile.writeBytes(ByteArray(0))
            }
            currentFile.appendBytes(entryBytes)
        } catch (t: Throwable) {
            // ignore（ログ自体の失敗でアプリを止めない）
        }
    }

    /**
     * current -> backupへのrotationを試みる。delete/renameの戻り値を
     * 確認し、失敗した場合もfail-safeでboundを守る（古いdiagnosticを
     * 失ってもよい。呼び出し元[appendLineBounded]の追加チェックが
     * 最終的な保証を担う）。
     */
    private fun rotate() {
        try {
            if (backupFile.exists()) {
                val deleted = backupFile.delete()
                if (!deleted && backupFile.exists()) {
                    // 古いbackupを消せない場合、renameToが失敗する可能性が
                    // 高いため、backup自体をtruncateしてfail-safeとする。
                    backupFile.writeBytes(ByteArray(0))
                }
            }
            val renamed = currentFile.renameTo(backupFile)
            if (!renamed) {
                // renameが失敗した場合(異なるファイルシステム間等の稀な
                // ケース)でも、currentへの無制限appendだけは避ける。
                try {
                    currentFile.copyTo(backupFile, overwrite = true)
                } catch (t: Throwable) {
                    // コピーに失敗しても、直後のtruncateでboundは守られる
                    // (古いdiagnosticを失うことを許容するfail-safe)。
                }
                currentFile.writeBytes(ByteArray(0))
            }
        } catch (t: Throwable) {
            // rotate自体が失敗しても、呼び出し元(appendLineBounded)側の
            // 追加チェックが最終的にcurrentのboundを守る。
        }
    }

    /**
     * backup→currentの順で結合したboundedなsnapshot文字列を、callback経由で
     * 非同期に返す。診断情報取得専用であり、ACTION_SEND/PROCESS_TEXT
     * deliveryには使用しない。
     *
     * 呼び出し元スレッドをブロックしない。[callback]は本クラスの
     * background executorスレッド上で呼ばれるため、呼び出し元（例えば
     * MethodChannel.Result応答）がmain threadでの実行を必要とする場合は
     * 呼び出し元側でmain threadへpostすること。
     */
    fun getSnapshotAsync(callback: (String) -> Unit) {
        executor.execute {
            val snapshot = try {
                val backup = if (backupFile.exists()) backupFile.readText(Charsets.UTF_8) else ""
                val current = if (currentFile.exists()) currentFile.readText(Charsets.UTF_8) else ""
                backup + current
            } catch (t: Throwable) {
                ""
            }
            callback(snapshot)
        }
    }

    companion object {
        private const val CURRENT_FILE_NAME = "share_observability_current.log"
        private const val BACKUP_FILE_NAME = "share_observability_backup.log"

        // Persistent Share Observability Phase 1の既定retention上限。
        // current/backupそれぞれ256KB程度、合計最大512KB程度に抑える。
        private const val MAX_FILE_BYTES = 256 * 1024L

        // ChatGPT precommit review v2 Fix 2 (要件B): 1イベント(1行)全体の
        // UTF-8 byte数上限。極端に長い単一eventだけで巨大なentryを
        // 生成できないようにする。
        private const val MAX_LINE_BYTES = 4 * 1024

        // ChatGPT precommit review v2 Fix 2 (要件B): 個々のfield valueの
        // 文字数上限。action/type等のexternal inputが極端に長い場合の
        // 追加防御（行全体のMAX_LINE_BYTESとは独立した、field単位の上限）。
        private const val MAX_FIELD_VALUE_CHARS = 500

        @Volatile
        private var instance: NativeShareObservability? = null

        fun getInstance(context: Context): NativeShareObservability {
            return instance ?: synchronized(this) {
                instance ?: NativeShareObservability(context).also { instance = it }
            }
        }
    }
}
