package com.example.readaloud_app

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract

/**
 * Sources Folder Source の直下 children metadata 列挙（Phase 1）。
 *
 * 指定ツリー直下を1回の cursor で取得する。再帰はしない。本文は読まない。
 * `.md` 判定や 7 暦日 filter は Dart 側（取得した metadata に対して）で行い、
 * DocumentsProvider 側の selection 最適化には依存しない。
 */
internal object SourcesFolderListing {

    private val PROJECTION = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
    )

    /**
     * ツリー直下の子要素を返す。各要素は Map（uri/name/mimeType/lastModified/isDirectory）。
     * 0 件の正常 cursor は空リスト。cursor が null（provider 不達）は例外として
     * 呼び出し側の unavailable 経路へ流す。SecurityException は権限喪失として
     * 呼び出し側で区別できるよう再 throw する。
     */
    fun listDirectChildren(resolver: ContentResolver, treeUriString: String): List<Map<String, Any?>> {
        val treeUri = Uri.parse(treeUriString)
        val parentDocumentId = DocumentsContract.getTreeDocumentId(treeUri)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocumentId)

        val cursor = resolver.query(childrenUri, PROJECTION, null, null, null)
            ?: throw IllegalStateException("provider_unavailable: null cursor")

        val results = ArrayList<Map<String, Any?>>()
        cursor.use { c ->
            val idIndex = c.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = c.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeIndex = c.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val modifiedIndex = c.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            while (c.moveToNext()) {
                val documentId = c.getString(idIndex) ?: continue
                val mimeType = c.getString(mimeIndex) ?: ""
                val lastModified = if (c.isNull(modifiedIndex)) 0L else c.getLong(modifiedIndex)
                results.add(
                    mapOf(
                        "uri" to DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId).toString(),
                        "name" to (c.getString(nameIndex) ?: ""),
                        "mimeType" to mimeType,
                        "lastModified" to lastModified,
                        "isDirectory" to (mimeType == DocumentsContract.Document.MIME_TYPE_DIR),
                    ),
                )
            }
        }
        return results
    }
}
