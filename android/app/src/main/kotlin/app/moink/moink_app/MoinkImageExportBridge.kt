package app.moink.moink_app

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.ContentValues
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** User-initiated PNG export. No media-library read permission is requested. */
class MoinkImageExportBridge(activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {
    companion object {
        private const val PERMISSION_REQUEST = 8424
        private const val MAX_BYTES = 16 * 1024 * 1024
        private val PNG_SIGNATURE = byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10)
        private val PNG_END = byteArrayOf(0, 0, 0, 0, 73, 69, 78, 68, -82, 66, 96, -126)
    }

    private class ExportFailure(val code: String, message: String) : IOException(message)
    private class Request(val png: ByteArray, val fileName: String, val result: MethodChannel.Result) {
        @Volatile var cancelled = false
        var started = false // Accessed only on the platform thread.
    }

    private var activity: Activity? = activity
    private val context = activity.applicationContext
    private val channel = MethodChannel(messenger, "app.moink/image_export")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var active: Request? = null
    private var rationale: AlertDialog? = null
    @Volatile private var disposed = false

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "savePng") {
            result.notImplemented()
            return
        }
        if (disposed) {
            result.error("cancelled", "图片保存服务已关闭，请重新打开应用。", null)
            return
        }
        if (active != null) {
            result.error("busy", "正在保存另一张图片，请稍候。", null)
            return
        }
        val arguments = call.arguments as? Map<*, *>
        val png = arguments?.get("png") as? ByteArray
        val name = (arguments?.get("fileName") as? String)?.trim()
        if (png == null || png.size !in 45..MAX_BYTES ||
            !png.copyOfRange(0, 8).contentEquals(PNG_SIGNATURE) ||
            !png.copyOfRange(png.size - 12, png.size).contentEquals(PNG_END)) {
            result.error("invalid_image", "图片数据无效，请重新读取完整画面后再保存。", null)
            return
        }
        if (name == null || name.length < 5 || name.startsWith(".") ||
            !name.endsWith(".png", ignoreCase = true) || name.toByteArray(Charsets.UTF_8).size > 160 ||
            name.any { it.code < 32 || it.code == 127 || it in "/\\<>:\"|?*" }) {
            result.error("invalid_filename", "图片文件名无效，请使用简短的 PNG 文件名。", null)
            return
        }
        val request = Request(png, name, result)
        active = request
        val currentActivity = activity
        if (currentActivity == null || currentActivity.isFinishing || currentActivity.isDestroyed) {
            finish(request, error = ExportFailure("cancelled", "页面已关闭，请重新打开后保存。"))
        } else if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P &&
            currentActivity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            requestPermission(request, currentActivity)
        } else {
            start(request)
        }
    }

    private fun requestPermission(request: Request, currentActivity: Activity) {
        fun ask() {
            if (disposed || active !== request) return
            try {
                currentActivity.requestPermissions(
                    arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), PERMISSION_REQUEST
                )
            } catch (_: Exception) {
                finish(request, error = ExportFailure("permission_denied", "无法请求存储权限，请在系统设置中允许后重试。"))
            }
        }
        if (currentActivity.shouldShowRequestPermissionRationale(Manifest.permission.WRITE_EXTERNAL_STORAGE)) {
            rationale = AlertDialog.Builder(currentActivity)
                .setTitle("保存图片到相册")
                .setMessage("此 Android 版本需要存储权限，才能把图片保存到 Pictures/MoInk。")
                .setPositiveButton("继续") { _, _ -> ask() }
                .setNegativeButton("取消") { _, _ ->
                    finish(request, error = ExportFailure("cancelled", "已取消保存。"))
                }
                .setOnCancelListener {
                    finish(request, error = ExportFailure("cancelled", "已取消保存。"))
                }
                .create()
            rationale?.show()
        } else {
            ask()
        }
    }

    fun onPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_REQUEST || disposed) return
        val request = active ?: return
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED &&
            activity?.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED) {
            start(request)
        } else {
            finish(request, error = ExportFailure("permission_denied", "未获得存储权限，图片未保存。可在系统设置中允许后重试。"))
        }
    }

    private fun start(request: Request) {
        if (request.started || disposed || active !== request) return
        request.started = true
        worker.execute {
            try {
                checkActive(request)
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(request.png, 0, request.png.size, bounds)
                if (bounds.outMimeType != "image/png" || bounds.outWidth !in 1..8192 ||
                    bounds.outHeight !in 1..8192 || bounds.outWidth.toLong() * bounds.outHeight > 32_000_000L) {
                    throw ExportFailure("invalid_image", "无法识别这张 PNG 图片，请重新读取完整画面。")
                }
                val message = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    saveScoped(request)
                } else {
                    saveLegacy(request)
                }
                main.post { finish(request, message = message) }
            } catch (error: Exception) {
                val failure = when (error) {
                    is ExportFailure -> error
                    is SecurityException -> ExportFailure("permission_denied", "保存权限不可用，请在系统设置中检查权限后重试。")
                    else -> ExportFailure("save_failed", "图片保存失败，请检查存储空间后重试。")
                }
                main.post { finish(request, error = failure) }
            }
        }
    }

    private fun checkActive(request: Request) {
        if (request.cancelled || disposed) throw ExportFailure("cancelled", "保存操作已中断，请检查相册后重试。")
    }

    private fun uniqueName(request: Request): String =
        "${request.fileName.dropLast(4)}-${UUID.randomUUID()}.png"

    private fun writeBytes(request: Request, stream: OutputStream) {
        var offset = 0
        while (offset < request.png.size) {
            checkActive(request)
            val length = minOf(64 * 1024, request.png.size - offset)
            stream.write(request.png, offset, length)
            offset += length
        }
        stream.flush()
        checkActive(request)
    }

    private fun saveScoped(request: Request): String {
        val resolver = context.contentResolver
        val name = uniqueName(request)
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/MoInk")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        checkActive(request)
        // Every export creates a new row; never open an existing photo for writing.
        val uri = resolver.insert(
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values
        ) ?: throw IOException("MediaStore insert returned null")
        try {
            resolver.openOutputStream(uri, "w")?.use { writeBytes(request, it) }
                ?: throw IOException("MediaStore output stream returned null")
            checkActive(request)
            if (resolver.update(uri, ContentValues().apply {
                    put(MediaStore.Images.Media.IS_PENDING, 0)
                }, null, null) != 1) throw IOException("MediaStore commit failed")
        } catch (error: Exception) {
            try { resolver.delete(uri, null, null) } catch (_: Exception) { /* Best-effort rollback. */ }
            throw error
        }
        // OEM providers may adjust the display name; read only our newly-created row.
        val actualName = try {
            resolver.query(uri, arrayOf(MediaStore.Images.Media.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            } ?: name
        } catch (_: Exception) { name }
        return "已保存到相册：Pictures/MoInk/$actualName"
    }

    @Suppress("DEPRECATION")
    private fun saveLegacy(request: Request): String {
        if (Environment.getExternalStorageState() != Environment.MEDIA_MOUNTED) {
            throw ExportFailure("storage_unavailable", "手机共享存储暂不可写，请检查存储状态后重试。")
        }
        val directory = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "MoInk")
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Cannot create Pictures/MoInk")
        val file = File(directory, uniqueName(request))
        if (!file.createNewFile()) throw IOException("Unique destination already exists")
        try {
            FileOutputStream(file).use {
                writeBytes(request, it)
                it.fd.sync()
            }
            checkActive(request)
        } catch (error: Exception) {
            file.delete()
            throw error
        }
        // The file is complete. Scan it so gallery apps can discover it.
        val scanned = CountDownLatch(1)
        val scannedUri = AtomicReference<Uri?>()
        try {
            MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), arrayOf("image/png")) { _, uri ->
                scannedUri.set(uri)
                scanned.countDown()
            }
            scanned.await(10, TimeUnit.SECONDS)
        } catch (_: Exception) { /* The completed file remains available even if indexing is delayed. */ }
        return if (scannedUri.get() != null) {
            "已保存到相册：Pictures/MoInk/${file.name}"
        } else {
            "已保存到：Pictures/MoInk/${file.name}（相册索引可能稍后更新）"
        }
    }

    private fun finish(request: Request, message: String? = null, error: ExportFailure? = null) {
        if (disposed || active !== request) return
        active = null
        rationale = null
        if (error == null) request.result.success(message)
        else request.result.error(error.code, error.message, null)
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        val request = active
        active = null
        request?.cancelled = true
        request?.result?.error("cancelled", "页面已关闭，保存操作已中断；请检查相册后重试。", null)
        rationale?.dismiss()
        rationale = null
        activity = null
        channel.setMethodCallHandler(null)
        // Running I/O observes cancellation and cleans up any unfinished entry.
        worker.shutdown()
    }
}
