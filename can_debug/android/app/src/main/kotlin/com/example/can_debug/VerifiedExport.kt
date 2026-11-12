package com.example.can_debug

import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest

data class ExportVerification(val bytes: Long, val sha256: String)

/** Bounded-memory copy, then an independent read of the closed document. */
object VerifiedExport {
    private fun digest(input: InputStream): ExportVerification {
        val hash = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        var count = 0L
        input.use {
            while (true) {
                val n = it.read(buffer)
                if (n < 0) break
                if (n == 0) continue
                hash.update(buffer, 0, n)
                count += n
            }
        }
        return ExportVerification(count, hash.digest().joinToString("") { "%02x".format(it) })
    }

    fun copy(source: File, expectedBytes: Long, expectedSha256: String,
        openOutput: () -> OutputStream, openInput: () -> InputStream): ExportVerification {
        require(expectedBytes > 0) { "Empty export payload" }
        check(source.isFile && source.length() == expectedBytes) { "Staged export size mismatch" }
        val original = digest(source.inputStream())
        check(original.bytes == expectedBytes && original.sha256 == expectedSha256) {
            "Staged export checksum mismatch"
        }
        // Verify the source before opening/truncating the destination.
        val copied = openOutput().use { output ->
            source.inputStream().use { input -> input.copyTo(output, 64 * 1024) }
                .also { output.flush() }
        }
        check(copied == expectedBytes) { "Incomplete document write: $copied / $expectedBytes bytes" }
        val actual = digest(openInput())
        check(actual.bytes == expectedBytes && actual.sha256 == expectedSha256) {
            "Destination verification failed: ${actual.bytes} / $expectedBytes bytes"
        }
        return actual
    }
}
