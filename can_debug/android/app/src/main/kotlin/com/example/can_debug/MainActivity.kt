package com.example.can_debug

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    companion object { private val copying = AtomicBoolean(false) }
    private lateinit var exportChannel: MethodChannel
    private val exportRequest = 27041
    private var launchedHere = false
    private val exportPrefs get() = getSharedPreferences("can_debug_exports", MODE_PRIVATE)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        exportChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "can_debug/session_export")
        exportChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "saveDocument" -> {
                    try {
                        check(!copying.get()) { "Another export is in progress" }
                        val existing = pending()
                        check(existing == null || existing.optString("state") == "error") {
                            "An unfinished export exists; resume it before starting another"
                        }
                        val source = checkedSource(call.argument<String>("sourcePath") ?: error("Missing source"))
                        val expected = (call.argument<Number>("bytes") ?: error("Missing byte count")).toLong()
                        val hash = call.argument<String>("sha256") ?: error("Missing checksum")
                        require(expected > 0 && source.length() == expected) { "Empty or incomplete staged file" }
                        require(hash.matches(Regex("[0-9a-f]{64}"))) { "Invalid checksum" }
                        val request = JSONObject().apply {
                            put("id", source.name)
                            put("sourcePath", source.path)
                            put("name", call.argument<String>("name") ?: "session.json")
                            put("mime", call.argument<String>("mime") ?: "application/octet-stream")
                            put("bytes", expected)
                            put("sha256", hash)
                            put("state", "awaiting_destination")
                        }
                        savePending(request)
                        exportPrefs.edit().remove("completed").commit()
                        launchPicker(request)
                        result.success(mapOf("id" to request.getString("id"), "state" to "awaiting_destination"))
                    } catch (e: Exception) {
                        result.error("EXPORT_START_FAILED", e.message, null)
                    }
                }
                "exportStatus" -> {
                    val completed = exportPrefs.getString("completed", null)?.let { JSONObject(it) }
                    result.success((completed ?: pending())?.let { asMap(it) })
                }
                "acknowledgeExport" -> {
                    val completed = exportPrefs.getString("completed", null)?.let { JSONObject(it) }
                    if (completed?.optString("id") == call.argument<String>("id")) {
                        exportPrefs.edit().remove("completed").commit()
                    }
                    result.success(null)
                }
                "resumeExport" -> {
                    try {
                        val request = pending() ?: error("No unfinished export")
                        if (!copying.get()) {
                            exportPrefs.edit().remove("completed").commit()
                            if (request.has("uri")) {
                                request.put("state", "writing")
                                savePending(request)
                                copyDocument(request)
                            } else launchPicker(request)
                        }
                        result.success(null)
                    } catch (e: Exception) { result.error("EXPORT_RESUME_FAILED", e.message, null) }
                }
                else -> result.notImplemented()
            }
        }
        // Recover without relying on an in-memory Dart Future or Activity field.
        val request = pending()
        if (request?.optString("state") == "writing" && request.has("uri")) copyDocument(request)
    }

    private fun checkedSource(path: String): File {
        val source = File(path).canonicalFile
        val directory = File(filesDir, "pending_exports").canonicalFile
        require(source.parentFile == directory && source.isFile) { "Invalid staged export path" }
        return source
    }

    private fun pending(): JSONObject? = exportPrefs.getString("pending", null)?.let { JSONObject(it) }

    private fun savePending(request: JSONObject) {
        check(exportPrefs.edit().putString("pending", request.toString()).commit()) {
            "Cannot persist export state"
        }
    }

    private fun launchPicker(request: JSONObject) {
        launchedHere = true
        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = request.getString("mime")
            putExtra(Intent.EXTRA_TITLE, request.getString("name"))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }, exportRequest)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != exportRequest) return
        val request = pending() ?: return
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            finishExport(request, JSONObject().put("state", "cancelled"))
            return
        }
        try {
            val grants = (data?.flags ?: 0) and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            try { contentResolver.takePersistableUriPermission(uri, grants) }
            catch (e: SecurityException) { Log.w("CanExport", "Provider did not grant persistent URI access", e) }
            request.put("uri", uri.toString()).put("state", "writing")
            savePending(request)
            copyDocument(request)
        } catch (e: Exception) { failExport(request, e) }
    }

    private fun copyDocument(request: JSONObject) {
        if (!copying.compareAndSet(false, true)) return
        Thread {
            try {
                val source = checkedSource(request.getString("sourcePath"))
                val uri = Uri.parse(request.getString("uri"))
                Log.i("CanExport", "Copying ${request.getLong("bytes")} bytes; restored=${!launchedHere}")
                val verified = VerifiedExport.copy(source, request.getLong("bytes"), request.getString("sha256"),
                    { contentResolver.openOutputStream(uri, "wt") ?: error("Destination not writable") },
                    { contentResolver.openInputStream(uri) ?: error("Destination not readable for verification") })
                val name = try {
                    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                        if (it.moveToFirst()) it.getString(0) else null
                    }
                } catch (_: Exception) { null }
                val receipt = JSONObject().put("state", "saved").put("uri", uri.toString())
                    .put("name", name ?: request.getString("name"))
                    .put("bytes", verified.bytes).put("sha256", verified.sha256)
                runOnUiThread { finishExport(request, receipt) }
            } catch (e: Exception) { runOnUiThread { failExport(request, e) } }
        }.start()
    }

    private fun failExport(request: JSONObject, error: Exception) {
        Log.e("CanExport", "Export not completed", error)
        val message = "Export failed; destination may be empty or partial: ${error.message}"
        request.put("state", "error").put("message", message)
        try { savePending(request) }
        catch (e: Exception) { Log.e("CanExport", "Cannot persist failure state", e) }
        val receipt = JSONObject().put("state", "error").put("message", message)
        finishExport(request, receipt, retainPending = true)
    }

    private fun finishExport(request: JSONObject, receipt: JSONObject, retainPending: Boolean = false) {
        copying.set(false)
        receipt.put("id", request.getString("id"))
        val edit = exportPrefs.edit().putString("completed", receipt.toString())
        if (!retainPending) edit.remove("pending")
        if (!edit.commit()) {
            Log.e("CanExport", "Cannot persist export result; staged payload retained")
            return
        }
        if (!retainPending) File(request.getString("sourcePath")).delete()
        if (!isDestroyed) exportChannel.invokeMethod("exportResultAvailable", null)
        Log.i("CanExport", "Export ${receipt.getString("state")}; bytes=${receipt.optLong("bytes")}")
    }

    private fun asMap(json: JSONObject): Map<String, Any?> = json.keys().asSequence().associateWith {
        if (json.isNull(it)) null else json.get(it)
    }
}
