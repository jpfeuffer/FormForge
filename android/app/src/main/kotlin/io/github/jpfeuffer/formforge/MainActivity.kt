package io.github.jpfeuffer.formforge

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private val requestCode = 4201

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "formforge/shared_file")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pick", "create" -> {
                        if (pending != null) {
                            result.error("busy", "Another document picker is open", null)
                        } else {
                            pending = result
                            val intent = Intent(
                                if (call.method == "create") Intent.ACTION_CREATE_DOCUMENT
                                else Intent.ACTION_OPEN_DOCUMENT
                            ).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = if (call.method == "create") "application/octet-stream" else "*/*"
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                                if (call.method == "create") putExtra(Intent.EXTRA_TITLE, "training.formforge")
                            }
                            try {
                                startActivityForResult(intent, requestCode)
                            } catch (e: Exception) {
                                pending = null
                                result.error("picker", e.message, null)
                            }
                        }
                    }
                    "read", "write" -> {
                        val uriString = call.argument<String>("uri")
                        if (uriString == null) {
                            result.error("document", "Missing document URI", null)
                            return@setMethodCallHandler
                        }
                        val path = call.argument<String>("path")
                        Thread {
                            var temporary: File? = null
                            try {
                                val uri = Uri.parse(uriString)
                                if (call.method == "read") {
                                    val file = File.createTempFile("formforge-read-", ".backup", cacheDir)
                                    temporary = file
                                    contentResolver.openInputStream(uri).use { input ->
                                        requireNotNull(input) { "Provider cannot read this document" }
                                        file.outputStream().use { output ->
                                            val buffer = ByteArray(65536)
                                            var total = 0L
                                            while (true) {
                                                val count = input.read(buffer)
                                                if (count < 0) break
                                                total += count
                                                require(total <= 512L * 1024 * 1024) { "Backup is too large" }
                                                output.write(buffer, 0, count)
                                            }
                                        }
                                    }
                                    runOnUiThread { result.success(file.path) }
                                } else {
                                    requireNotNull(path) { "Missing upload file" }
                                    contentResolver.openOutputStream(uri, "wt").use { output ->
                                        requireNotNull(output) { "Provider cannot overwrite this document" }
                                        File(path).inputStream().use { it.copyTo(output) }
                                    }
                                    runOnUiThread { result.success(null) }
                                }
                            } catch (e: Exception) {
                                temporary?.delete()
                                runOnUiThread { result.error("document", e.message, null) }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != this.requestCode) return
        val result = pending ?: return
        pending = null
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return
        }
        try {
            val selected = requireNotNull(data) { "No document selected" }
            val uri = requireNotNull(selected.data) { "No document selected" }
            val required = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            require((selected.flags and required) == required) { "Choose a provider with read/write document access" }
            contentResolver.takePersistableUriPermission(uri, required)
            contentResolver.query(
                uri, arrayOf(DocumentsContract.Document.COLUMN_FLAGS), null, null, null
            ).use { cursor ->
                require(cursor != null && cursor.moveToFirst()) { "Cannot inspect document capabilities" }
                require((cursor.getInt(0) and DocumentsContract.Document.FLAG_SUPPORTS_WRITE) != 0) {
                    "This provider does not support updating the selected file"
                }
            }
            result.success(uri.toString())
        } catch (e: Exception) {
            result.error("document", e.message, null)
        }
    }
}
