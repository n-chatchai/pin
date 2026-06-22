package io.tokens2.pin

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import java.io.File

/// Full-screen camera with a สแกน · รูปภาพ · วิดีโอ mode switcher and an X close —
/// the Android twin of the iOS VisionKit camera. Returns to Flutter via Intent
/// extras (read in MainActivity.onActivityResult):
///   photo → path + isVideo=false   video → path + isVideo=true   scan → paths[]
class CameraActivity : ComponentActivity() {
    private enum class Mode { SCAN, PHOTO, VIDEO }

    private lateinit var previewView: PreviewView
    private lateinit var captureBtn: View
    private lateinit var modeRow: LinearLayout
    private var provider: ProcessCameraProvider? = null
    private var imageCapture: ImageCapture? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var recording: Recording? = null
    private var lensFacing = CameraSelector.LENS_FACING_BACK
    private var flashOn = false
    private var mode = Mode.PHOTO
    private var audioGranted = false
    private var finished = false
    private var cancelled = false // ✕ pressed mid-recording → discard the clip

    private val scanLauncher =
        registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { res ->
            val scan = GmsDocumentScanningResult.fromActivityResultIntent(res.data)
            val paths = ArrayList<String>()
            scan?.pages?.forEach { page -> copyToCache(page.imageUri)?.let { paths.add(it) } }
            if (paths.isNotEmpty()) {
                val data = Intent().putStringArrayListExtra("paths", paths)
                setResult(Activity.RESULT_OK, data); finish()
            } else if (mode == Mode.SCAN && provider == null) {
                // Pure-scan entry (channel "scan") and the user backed out.
                finish()
            }
            // else: scan tab inside camera, cancelled → stay on camera.
        }

    private val permLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
            if (grants[Manifest.permission.CAMERA] != true) {
                Toast.makeText(this, "ต้องขอสิทธิ์กล้องก่อนนะ", Toast.LENGTH_SHORT).show()
                finish(); return@registerForActivityResult
            }
            audioGranted = grants[Manifest.permission.RECORD_AUDIO] == true
            startCamera()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Channel "scan" → go straight to the document scanner, no camera preview.
        if (intent.getStringExtra("startMode") == "scan") {
            mode = Mode.SCAN
            buildScanOnlyShell()
            launchScanner()
            return
        }
        buildUI()
        permLauncher.launch(arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO))
    }

    // MARK: UI -----------------------------------------------------------------

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun buildScanOnlyShell() {
        val root = FrameLayout(this)
        root.setBackgroundColor(Color.BLACK)
        setContentView(root)
    }

    private fun buildUI() {
        val root = FrameLayout(this)
        root.setBackgroundColor(Color.BLACK)

        previewView = PreviewView(this)
        root.addView(previewView, FrameLayout.LayoutParams(-1, -1))

        root.addView(roundButton("✕") { close() }, corner(Gravity.TOP or Gravity.START, 16, 14))
        root.addView(roundButton("⟳") { flip() }, corner(Gravity.TOP or Gravity.END, 16, 14))
        root.addView(roundButton("⚡") { toggleFlash(it as TextView) }, corner(Gravity.TOP or Gravity.END, 16, 70))

        // Capture button.
        captureBtn = View(this)
        captureBtn.background = captureDrawable(false)
        FrameLayout.LayoutParams(dp(76), dp(76)).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            bottomMargin = dp(56)
            root.addView(captureBtn, this)
        }
        captureBtn.setOnClickListener { onCapture() }

        // Mode switcher.
        modeRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        Mode.values().forEachIndexed { _, m ->
            val tv = TextView(this).apply {
                text = when (m) { Mode.SCAN -> "สแกน"; Mode.PHOTO -> "รูปภาพ"; Mode.VIDEO -> "วิดีโอ" }
                setTextColor(Color.WHITE)
                textSize = 15f
                setPadding(dp(14), dp(6), dp(14), dp(6))
                setOnClickListener { selectMode(m) }
            }
            modeRow.addView(tv)
        }
        FrameLayout.LayoutParams(-2, -2).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            bottomMargin = dp(16)
            root.addView(modeRow, this)
        }
        setContentView(root)
        refreshModeLabels()
    }

    private fun corner(gravity: Int, x: Int, y: Int) =
        FrameLayout.LayoutParams(dp(42), dp(42)).apply {
            this.gravity = gravity
            marginStart = dp(x); marginEnd = dp(x); topMargin = dp(y)
        }

    private fun roundButton(glyph: String, onTap: (View) -> Unit): TextView {
        return TextView(this).apply {
            text = glyph
            setTextColor(Color.WHITE)
            textSize = 18f
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.argb(90, 0, 0, 0))
            }
            setOnClickListener { onTap(this) }
        }
    }

    private fun captureDrawable(red: Boolean) = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(if (red) Color.RED else Color.WHITE)
        setStroke(dp(5), Color.WHITE)
    }

    private fun refreshModeLabels() {
        for (i in 0 until modeRow.childCount) {
            val tv = modeRow.getChildAt(i) as TextView
            tv.alpha = if (i == mode.ordinal) 1f else 0.5f
        }
        captureBtn.background = captureDrawable(mode == Mode.VIDEO)
    }

    // MARK: camera -------------------------------------------------------------

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            provider = future.get()
            bindUseCases()
        }, ContextCompat.getMainExecutor(this))
    }

    private fun bindUseCases() {
        val p = provider ?: return
        p.unbindAll()
        val selector = CameraSelector.Builder().requireLensFacing(lensFacing).build()
        val preview = Preview.Builder().build().also {
            it.setSurfaceProvider(previewView.surfaceProvider)
        }
        try {
            if (mode == Mode.VIDEO) {
                val recorder = Recorder.Builder()
                    .setQualitySelector(QualitySelector.from(Quality.HD)).build()
                videoCapture = VideoCapture.withOutput(recorder)
                imageCapture = null
                p.bindToLifecycle(this, selector, preview, videoCapture)
            } else {
                imageCapture = ImageCapture.Builder()
                    .setFlashMode(if (flashOn) ImageCapture.FLASH_MODE_ON else ImageCapture.FLASH_MODE_OFF)
                    .build()
                videoCapture = null
                p.bindToLifecycle(this, selector, preview, imageCapture)
            }
        } catch (e: Exception) {
            Toast.makeText(this, "เปิดกล้องไม่ได้", Toast.LENGTH_SHORT).show()
            finish()
        }
    }

    private fun selectMode(m: Mode) {
        if (recording != null) return
        if (m == Mode.SCAN) { launchScanner(); return }
        if (m == mode) return
        mode = m
        refreshModeLabels()
        bindUseCases()
    }

    private fun flip() {
        if (recording != null) return
        lensFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK)
            CameraSelector.LENS_FACING_FRONT else CameraSelector.LENS_FACING_BACK
        bindUseCases()
    }

    private fun toggleFlash(tv: TextView) {
        flashOn = !flashOn
        tv.alpha = if (flashOn) 1f else 0.55f
        if (mode != Mode.VIDEO) bindUseCases()
    }

    private fun onCapture() {
        when (mode) {
            Mode.SCAN -> launchScanner()
            Mode.PHOTO -> takePhoto()
            Mode.VIDEO -> toggleRecording()
        }
    }

    private fun takePhoto() {
        val ic = imageCapture ?: return
        val file = File(cacheDir, "pin_cam_${System.currentTimeMillis()}.jpg")
        val opts = ImageCapture.OutputFileOptions.Builder(file).build()
        ic.takePicture(opts, ContextCompat.getMainExecutor(this),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(o: ImageCapture.OutputFileResults) {
                    val data = Intent().putExtra("path", file.absolutePath).putExtra("isVideo", false)
                    setResult(Activity.RESULT_OK, data); finish()
                }
                override fun onError(e: ImageCaptureException) {
                    Toast.makeText(this@CameraActivity, "ถ่ายรูปไม่ได้", Toast.LENGTH_SHORT).show()
                }
            })
    }

    @Suppress("MissingPermission")
    private fun toggleRecording() {
        val vc = videoCapture ?: return
        val active = recording
        if (active != null) { active.stop(); return }
        captureBtn.background = captureDrawable(true)
        val file = File(cacheDir, "pin_vid_${System.currentTimeMillis()}.mp4")
        val opts = FileOutputOptions.Builder(file).build()
        var pending = vc.output.prepareRecording(this, opts)
        if (audioGranted) pending = pending.withAudioEnabled()
        recording = pending.start(ContextCompat.getMainExecutor(this)) { event ->
            if (event is VideoRecordEvent.Finalize) {
                recording = null
                // ✕ during recording → discard, don't send the clip.
                if (cancelled) {
                    file.delete(); finish(); return@start
                }
                if (event.hasError()) {
                    Toast.makeText(this, "อัดวิดีโอไม่ได้", Toast.LENGTH_SHORT).show()
                    refreshModeLabels()
                } else {
                    val data = Intent().putExtra("path", file.absolutePath).putExtra("isVideo", true)
                    setResult(Activity.RESULT_OK, data); finish()
                }
            }
        }
    }

    // MARK: scan ---------------------------------------------------------------

    private fun launchScanner() {
        val options = GmsDocumentScannerOptions.Builder()
            .setGalleryImportAllowed(false)
            .setPageLimit(15)
            .setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_JPEG)
            .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)
            .build()
        GmsDocumentScanning.getClient(options).getStartScanIntent(this)
            .addOnSuccessListener { sender ->
                scanLauncher.launch(IntentSenderRequest.Builder(sender).build())
            }
            .addOnFailureListener {
                Toast.makeText(this, "สแกนเอกสารไม่ได้", Toast.LENGTH_SHORT).show()
                if (provider == null) finish() // pure-scan entry
            }
    }

    private fun copyToCache(uri: Uri?): String? {
        if (uri == null) return null
        return try {
            val file = File(cacheDir, "pin_scan_${System.currentTimeMillis()}_${uri.lastPathSegment?.hashCode()}.jpg")
            contentResolver.openInputStream(uri)!!.use { input ->
                file.outputStream().use { input.copyTo(it) }
            }
            file.absolutePath
        } catch (e: Exception) { null }
    }

    private fun close() {
        // If recording, stop+discard (finalize sees `cancelled` → deletes the
        // clip, finishes RESULT_CANCELED). Otherwise just cancel out.
        val active = recording
        if (active != null) { cancelled = true; active.stop(); return }
        finish()
    }

    override fun finish() {
        if (!finished) { finished = true; super.finish() } else super.finish()
    }
}
