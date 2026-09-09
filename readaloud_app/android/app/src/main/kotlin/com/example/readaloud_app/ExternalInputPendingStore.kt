package com.example.readaloud_app

/**
 * No.94 Share Event Architecture（Architecture Z、
 * No94_ShareEvent_Architecture_Design_20260908_v3.md +
 * v3_addendum.md参照）。
 *
 * [ExternalInputEntryActivity]がcaptureしたACTION_SEND/
 * ACTION_PROCESS_TEXTペイロードの唯一の情報源。[MainActivity]側の
 * 統合MethodChannelハンドラが[pull]で読み取ると同時にclearする
 * （atomic consume、single slot、queueなし、latest-wins）。
 *
 * process lifetimeで生存するsingletonとして保持する（
 * [ExternalInputEntryActivity]と[MainActivity]という別Activity
 * instance間でこのstateを共有する必要があるため）。Intent配信・
 * MethodChannel呼び出しはすべてAndroid main/platform thread上でのみ
 * 行われるため（Activity lifecycle callbackとFlutter
 * MethodChannelハンドラは共にmain threadで実行される、
 * Architecture Design v2 §2参照）、`@Volatile`以上の同期は不要
 * （既存5709c892の`pendingActionSendText`等と同じ前提）。
 */
object ExternalInputPendingStore {
    /**
     * @property source "action_send" または "process_text"
     *   （observability/ログ用の分類。routing判定には使わない）。
     * @property kind "text" または "url"（既存`SharedContentKind`に
     *   対応。ACTION_SENDのみnative `URLUtil.isValidUrl`で判定、
     *   ACTION_PROCESS_TEXTは常に"text"固定）。
     * @property text 本文（永続ログしない）。
     */
    data class Envelope(
        val source: String,
        val kind: String,
        val text: String,
    )

    @Volatile
    private var pending: Envelope? = null

    /** 既存pendingをlatest-winsで上書きする（queueなし）。 */
    fun capture(envelope: Envelope) {
        pending = envelope
    }

    /** 現在のenvelopeを返すと同時にpendingをclearする（atomic consume）。 */
    fun pull(): Envelope? {
        val current = pending
        pending = null
        return current
    }

    fun hasPending(): Boolean = pending != null
}
