package com.lib.flutter_blue_plus;

import org.junit.Test;
import static org.junit.Assert.*;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

public class BleNativeTraceTest {
    private BleRawJournal journal(File files, int capacity, BleRawJournal.SinkFactory sink) {
        return new BleRawJournal(files, capacity, sink, (from, to) ->
            Files.move(from.toPath(), to.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                java.nio.file.StandardCopyOption.ATOMIC_MOVE));
    }
    private File temporary() throws IOException { return Files.createTempDirectory("ble-native-test-").toFile(); }
    private String manifest(BleRawJournal journal) throws IOException {
        return new String(Files.readAllBytes(new File(journal.directory(), "manifest.json").toPath()), StandardCharsets.UTF_8);
    }

    @Test public void mutationChangesOriginalButNeverChannelSnapshot() {
        byte[] upstream = "{\"t\":\"f\",\"seq\":16480}".getBytes(StandardCharsets.UTF_8);
        BleValueSnapshot value = new BleValueSnapshot(upstream, true);
        byte[] expected = upstream.clone();
        upstream[upstream.length - 2] = '8';
        BleValueSnapshot.Comparison proof = value.compareAndRelease();
        assertTrue(proof.compared);
        assertFalse(proof.unchanged);
        assertArrayEquals(expected, value.bytes);
        assertNotEquals(BleValueSnapshot.sha256(value.bytes), BleValueSnapshot.sha256(proof.originalAtDispatch));
        upstream[0] = 'x';
        assertEquals('{', proof.originalAtDispatch[0]);
        assertFalse(value.compareAndRelease().compared); // Original reference was consumed.
    }

    @Test public void unchangedBytesNullsAndDisabledProbeRemainCompatible() {
        byte[] input = {0, (byte) 255};
        BleValueSnapshot value = new BleValueSnapshot(input, true);
        assertNotSame(input, value.bytes);
        assertTrue(value.compareAndRelease().unchanged);
        BleValueSnapshot noProbe = new BleValueSnapshot(input, false);
        input[0] = 42;
        assertEquals(0, noProbe.bytes[0]);
        assertFalse(noProbe.compareAndRelease().compared);
        BleValueSnapshot nullable = new BleValueSnapshot(null, true);
        assertNull(nullable.bytes);
        assertTrue(nullable.compareAndRelease().unchanged);
        assertNull(BleValueSnapshot.sha256(null));
    }

    @Test public void fullLongTelemetryAndOrderingSurviveAsyncDiskQueue() throws Exception {
        File dir = temporary();
        BleRawJournal journal = journal(dir, 1024, FileOutputStream::new);
        String ff12 = "{\"t\":\"s\",\"fw\":\"" + "x".repeat(3000) + "\"}";
        long first = journal.begin(), second = journal.begin();
        journal.record("{\"callback_n\":" + first + ",\"hex\":\"" + BleValueSnapshot.hex(ff12.getBytes(StandardCharsets.UTF_8)) + "\"}", false);
        journal.record("{\"callback_n\":" + second + "}", false);
        journal.closeAsync();
        assertTrue(journal.awaitClosed(5000));
        java.util.List<String> lines = Files.readAllLines(new File(journal.directory(), "notifications.jsonl").toPath());
        assertEquals(2, lines.size());
        assertTrue(lines.get(0).contains(BleValueSnapshot.hex(ff12.getBytes(StandardCharsets.UTF_8))));
        assertTrue(lines.get(1).contains("\"callback_n\":2"));
        String summary = manifest(journal);
        assertTrue(summary.contains("\"status\":\"closed\""));
        assertTrue(summary.contains("\"writtenRecords\":2"));
        assertTrue(summary.contains("\"flushedRecords\":2"));
        assertEquals(0, journal.dropped.get());
        assertEquals(0, journal.writeErrors.get());
    }

    @Test public void queueOverflowNeverWaitsForFileIOAndIsCounted() throws Exception {
        CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
        BleRawJournal journal = journal(temporary(), 2, file -> {
            entered.countDown();
            try { if (!release.await(5, TimeUnit.SECONDS)) throw new IOException("test timeout"); }
            catch (InterruptedException e) { throw new IOException(e); }
            return new FileOutputStream(file);
        });
        assertTrue(entered.await(3, TimeUnit.SECONDS));
        long started = System.nanoTime();
        for (int i = 0; i < 3; i++) { journal.begin(); journal.record("{}", false); }
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 500);
        assertEquals(1, journal.dropped.get());
        journal.closeAsync();
        release.countDown();
        assertTrue(journal.awaitClosed(5000));
        assertEquals(2, journal.written.get());
        assertTrue(manifest(journal).contains("\"droppedRecords\":1"));
    }

    @Test public void fileFailureIsVisibleAndDoesNotEscapeProducer() throws Exception {
        BleRawJournal journal = journal(temporary(), 2, file -> { throw new IOException("injected disk failure"); });
        if (journal.begin() != 0) journal.record("{}", true);
        assertTrue(journal.awaitClosed(5000));
        assertEquals(1, journal.writeErrors.get());
        assertEquals(0, journal.written.get());
        assertTrue(manifest(journal).contains("\"status\":\"error\""));
        assertTrue(manifest(journal).contains("injected disk failure"));
    }

    @Test public void adbStopMarkerClosesAndFlushesWithoutEngineShutdown() throws Exception {
        File files = temporary();
        BleRawJournal journal = journal(files, 1024, FileOutputStream::new);
        journal.begin(); journal.record("{}", false);
        assertTrue(new File(files, "ble_trace_stop").createNewFile());
        assertTrue(journal.awaitClosed(5000));
        assertFalse(journal.isAccepting());
        assertTrue(manifest(journal).contains("\"status\":\"closed\""));
        assertEquals(1, journal.written.get());
    }
}
