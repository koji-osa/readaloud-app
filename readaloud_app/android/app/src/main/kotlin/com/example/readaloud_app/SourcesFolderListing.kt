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
     * SecurityException は権限喪失として呼び出し側で区別できるよう再 throw する。
     */
    fun listDirectChildren(resolver: ContentResolver, treeUriString: String): List<Map<String, Any?>> {
        val treeUri = Uri.parse(treeUriString)
        val parentDocumentId = DocumentsContract.getTreeDocumentId(treeUri)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocumentId)

        val results = ArrayList<Map<String, Any?>>()
        resolver.query(childrenUri, PROJECTION, null, null, null)?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val modifiedIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            while (cursor.moveToNext()) {
                val documentId = cursor.getString(idIndex) ?: continue
                val mimeType = cursor.getString(mimeIndex) ?: ""
                val lastModified = if (cursor.isNull(modifiedIndex)) 0L else cursor.getLong(modifiedIndex)
                results.add(
                    mapOf(
                        "uri" to DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId).toString(),
                        "name" to (cursor.getString(nameIndex) ?: ""),
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
