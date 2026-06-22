package io.tokens2.pin

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val reqCamera = 7001
    private var pendingCamera: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "io.tokens2.pin/media")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Write bytes straight into the public Downloads folder (no save
                    // dialog, no cloud target). Returns the saved file name.
                    "saveDownload" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        val name = call.argument<String>("name") ?: "pin-file"
                        val mime = call.argument<String>("mime") ?: "application/octet-stream"
                        if (bytes == null) {
                            result.error("no_bytes", "bytes required", null); return@setMethodCallHandler
                        }
                        try {
                            result.success(saveToDownloads(bytes, name, mime))
                        } catch (e: Exception) {
                            result.error("save_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Native camera — full-screen Photo/Video/Scan, mirroring the iOS channel.
        MethodChannel(messenger, "io.tokens2.pin/camera")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open", "scan" -> {
                        if (pendingCamera != null) { result.success(null); return@setMethodCallHandler }
                        pendingCamera = result
                        val intent = Intent(this, CameraActivity::class.java)
                        if (call.method == "scan") intent.putExtra("startMode", "scan")
                        startActivityForResult(intent, reqCamera)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != reqCamera) return
        val result = pendingCamera ?: return
        pendingCamera = null
        if (resultCode != Activity.RESULT_OK || data == null) { result.success(null); return }
        val paths = data.getStringArrayListExtra("paths")
        if (paths != null && paths.isNotEmpty()) {
            result.success(mapOf("paths" to paths)); return
        }
        val path = data.getStringExtra("path")
        if (path != null) {
            result.success(mapOf("path" to path, "isVideo" to data.getBooleanExtra("isVideo", false)))
            return
        }
        result.success(null)
    }

    private fun saveToDownloads(bytes: ByteArray, name: String, mime: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = applicationContext.contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("insert failed")
            resolver.openOutputStream(uri)!!.use { it.write(bytes) }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return name
        }
        // Pre-Q fallback: app-specific external dir (no permission needed).
        val dir = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
        val file = File(dir, name)
        file.writeBytes(bytes)
        return file.absolutePath
    }
}
