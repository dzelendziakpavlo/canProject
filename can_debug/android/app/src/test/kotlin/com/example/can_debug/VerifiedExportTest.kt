package com.example.can_debug

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest

class VerifiedExportTest {
    private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it) }

    @Test fun copiesLargePayloadAndChecksClosedDestination() {
        val bytes = ByteArray(8_350_070) { (it % 251).toByte() }
        val source = File.createTempFile("export-test-", ".json")
        val destination = File.createTempFile("export-test-", ".out")
        try {
            source.writeBytes(bytes)
            val receipt = VerifiedExport.copy(source, bytes.size.toLong(), hash(bytes),
                { destination.outputStream() }, { destination.inputStream() })
            assertEquals(bytes.size.toLong(), receipt.bytes)
            assertEquals(hash(bytes), receipt.sha256)
            assertArrayEquals(bytes, destination.readBytes())
        } finally { source.delete(); destination.delete() }
    }

    @Test fun rejectsEmptyOrCorruptSourceBeforeOpeningDestination() {
        val source = File.createTempFile("export-test-", ".csv")
        var opened = false
        try {
            assertThrows(IllegalArgumentException::class.java) {
                VerifiedExport.copy(source, 0, hash(byteArrayOf()),
                    { opened = true; ByteArrayOutputStream() }, { ByteArrayInputStream(byteArrayOf()) })
            }
            source.writeText("csv header\n")
            assertThrows(IllegalStateException::class.java) {
                VerifiedExport.copy(source, source.length(), "0".repeat(64),
                    { opened = true; ByteArrayOutputStream() }, { source.inputStream() })
            }
            assertFalse(opened)
        } finally { source.delete() }
    }

    @Test fun rejectsProviderThatDiscardsBytesOrReturnsCorruptContent() {
        val bytes = "%PDF-1.7 verified fixture".toByteArray()
        val source = File.createTempFile("export-test-", ".pdf")
        try {
            source.writeBytes(bytes)
            for (wrong in listOf(byteArrayOf(), ByteArray(bytes.size))) {
                assertThrows(IllegalStateException::class.java) {
                    VerifiedExport.copy(source, source.length(), hash(bytes),
                        { ByteArrayOutputStream() }, { ByteArrayInputStream(wrong) })
                }
            }
        } finally { source.delete() }
    }

    @Test fun retryReadsDurableFileWithNoPriorWorkerState() {
        val source = File.createTempFile("export-test-", ".json")
        try {
            source.writeText("{\"frames\":[1,2,3]}")
            val length = source.length()
            val checksum = hash(source.readBytes())
            val newWorkerOutput = ByteArrayOutputStream()
            val receipt = VerifiedExport.copy(File(source.path), length, checksum,
                { newWorkerOutput }, { ByteArrayInputStream(newWorkerOutput.toByteArray()) })
            assertEquals(length, receipt.bytes)
        } finally { source.delete() }
    }
}
