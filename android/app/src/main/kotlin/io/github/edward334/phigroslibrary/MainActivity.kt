package io.github.edward334.phigroslibrary

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val exportChannelName = "io.github.edward334.phigroslibrary/phira_export"
    private val exportRequestCode = 33401
    private var pendingExportResult: MethodChannel.Result? = null
    private var pendingExportFiles: List<PezFile> = emptyList()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, exportChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "exportPezFiles" -> startPezExport(call.arguments, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun startPezExport(arguments: Any?, result: MethodChannel.Result) {
        if (pendingExportResult != null) {
            result.error("export_in_progress", "Another export is already in progress.", null)
            return
        }

        val files = parsePezFiles(arguments)
        if (files.isEmpty()) {
            result.success(mapOf("exported" to 0, "cancelled" to false))
            return
        }

        pendingExportFiles = files
        pendingExportResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
        startActivityForResult(intent, exportRequestCode)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != exportRequestCode) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val result = pendingExportResult
        val files = pendingExportFiles
        pendingExportResult = null
        pendingExportFiles = emptyList()

        if (result == null) {
            return
        }
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(mapOf("exported" to 0, "cancelled" to true))
            return
        }

        try {
            val treeUri = data.data!!
            val flags = data.flags and (
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
            contentResolver.takePersistableUriPermission(treeUri, flags)
            val exported = writePezFiles(treeUri, files)
            result.success(
                mapOf(
                    "exported" to exported,
                    "cancelled" to false,
                    "directory" to treeUri.toString(),
                )
            )
        } catch (error: Exception) {
            result.error("export_failed", error.message, null)
        }
    }

    private fun writePezFiles(treeUri: Uri, files: List<PezFile>): Int {
        val parentDocumentId = DocumentsContract.getTreeDocumentId(treeUri)
        val parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, parentDocumentId)
        var exported = 0
        for (file in files) {
            val targetUri = DocumentsContract.createDocument(
                contentResolver,
                parentUri,
                "application/octet-stream",
                file.name,
            ) ?: continue
            contentResolver.openOutputStream(targetUri, "w")?.use { output ->
                output.write(file.bytes)
                exported += 1
            }
        }
        return exported
    }

    private fun parsePezFiles(arguments: Any?): List<PezFile> {
        val root = arguments as? Map<*, *> ?: return emptyList()
        val files = root["files"] as? List<*> ?: return emptyList()
        return files.mapNotNull { item ->
            val file = item as? Map<*, *> ?: return@mapNotNull null
            val name = file["name"] as? String ?: return@mapNotNull null
            val bytes = file["bytes"] as? ByteArray ?: return@mapNotNull null
            PezFile(name = name, bytes = bytes)
        }
    }

    private data class PezFile(val name: String, val bytes: ByteArray)
}
