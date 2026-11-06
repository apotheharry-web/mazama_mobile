package com.example.mazama_mobile

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry.ActivityResultListener
import java.io.File

class TextScanner(private val activity: Activity) : MethodChannel.MethodCallHandler, ActivityResultListener {
    private var pendingResult: MethodChannel.Result? = null
    private var photoUri: Uri? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "scanLabel") {
            result.notImplemented()
            return
        }
        // "photos" picks one already on the phone; anything else (and a call without the argument) is the camera
        if (call.argument<String>("source") == "photos") pickPhoto(result) else scanLabel(result)
    }

    /// A photo already on the phone, through the system's own picker: it runs outside this app and hands back only
    /// the one photo chosen, so no storage permission is asked for, and no camera permission either.
    private fun pickPhoto(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("scan_in_progress", "A scan is already in progress.", null)
            return
        }
        pendingResult = result
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Intent(MediaStore.ACTION_PICK_IMAGES) // the photo picker
        } else {
            Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "image/*"
                addCategory(Intent.CATEGORY_OPENABLE)
            }
        }
        try {
            activity.startActivityForResult(intent, PICK_REQUEST_CODE)
        } catch (e: Exception) {
            pendingResult = null
            result.error("photos_launch_failed", e.message, null)
        }
    }

    private fun scanLabel(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("scan_in_progress", "A scan is already in progress.", null)
            return
        }
        if (!activity.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)) {
            result.error("no_camera", "This device has no camera.", null)
            return
        }
        pendingResult = result
        // Some camera apps (e.g. GrapheneOS's hardened camera) refuse an ACTION_IMAGE_CAPTURE request
        // with a FileProvider URI unless the CALLING app actually holds the granted CAMERA permission,
        // even though this app never touches Camera2/CameraX itself - so this always checks/requests it
        // first rather than assuming the manifest declaration alone is enough.
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            launchCamera()
        } else {
            ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.CAMERA), PERMISSION_REQUEST_CODE)
        }
    }

    /// Wired up from MainActivity.onRequestPermissionsResult (MainActivity.kt) - launches the camera
    /// once the worker has answered the permission prompt, or fails the pending scanLabel call if denied.
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val result = pendingResult
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            launchCamera()
        } else {
            pendingResult = null
            result?.error("camera_permission_denied", "Camera permission was denied.", null)
        }
        return true
    }

    private fun launchCamera() {
        val result = pendingResult ?: return
        // ACTION_IMAGE_CAPTURE without EXTRA_OUTPUT hands back only a tiny thumbnail - nowhere near enough
        // resolution for ML Kit to read small label text reliably - so this always asks for the full photo to
        // be written to a file this app owns, via a FileProvider URI (a raw file:// Uri can't be granted to
        // another app from API 24 on - the FileProvider in AndroidManifest.xml and res/xml/file_paths.xml are the entries
        // this depends on).
        // under cache/scans/, the one folder file_paths.xml shares
        val scansDir = File(activity.cacheDir, "scans").apply { mkdirs() }
        val photoFile = File(scansDir, "scan_${System.currentTimeMillis()}.jpg")
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", photoFile)
        photoUri = uri
        val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
            putExtra(MediaStore.EXTRA_OUTPUT, uri)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            activity.startActivityForResult(intent, REQUEST_CODE)
        } catch (e: Exception) {
            pendingResult = null
            photoUri = null
            result.error("camera_launch_failed", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == PICK_REQUEST_CODE) {
            val result = pendingResult ?: return true
            pendingResult = null
            val picked = data?.data
            if (resultCode != Activity.RESULT_OK || picked == null) {
                result.success(null) // backed out of the picker: ScanCancelled on the Dart side
            } else {
                recognizeText(picked, result)
            }
            return true
        }
        if (requestCode != REQUEST_CODE) return false
        val result = pendingResult ?: return true
        val uri = photoUri
        pendingResult = null
        photoUri = null
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        recognizeText(uri, result)
        return true
    }

    private fun recognizeText(uri: Uri, result: MethodChannel.Result) {
        val image = try {
            InputImage.fromFilePath(activity, uri)
        } catch (e: Exception) {
            result.error("no_image", "Could not read the photo.", e.message)
            return
        }
        val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        recognizer.process(image)
            .addOnSuccessListener { visionText ->
                val lines = visionText.textBlocks.flatMap { block -> block.lines.map { it.text } }
                result.success(lines)
            }
            .addOnFailureListener { e -> result.error("ocr_failed", e.message, null) }
    }

    companion object {
        private const val REQUEST_CODE = 0x5A4D
        private const val PERMISSION_REQUEST_CODE = 0x5A4E
        private const val PICK_REQUEST_CODE = 0x5A4F
    }
}
