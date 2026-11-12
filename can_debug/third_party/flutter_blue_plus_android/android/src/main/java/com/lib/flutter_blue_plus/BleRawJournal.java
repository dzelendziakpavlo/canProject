package com.lib.flutter_blue_plus;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/** Opt-in diagnostic journal. File I/O is confined to one worker thread. */
final class BleRawJournal {
    interface SinkFactory { OutputStream open(File file) throws IOException; }
    interface Replacer { void replace(File temporary, File destination) throws IOException; }
    final AtomicLong observed = new AtomicLong(), dispatched = new AtomicLong();
    final AtomicLong enqueued = new AtomicLong(), written = new AtomicLong();
    final AtomicLong dropped = new AtomicLong(), writeErrors = new AtomicLong();
    final AtomicLong originalChanges = new AtomicLong();
    private final ArrayBlockingQueue<String> queue;
    private final File root, directory, stopFile;
    private final SinkFactory sinkFactory;
    private final Replacer replacer;
    private final Thread worker;
    private final int capacity;
    private volatile boolean stopping, finished;
    private long closeRequestedNanos, flushed;
    private volatile String failure;

    BleRawJournal(File filesDir) {
        this(filesDir, 1024, FileOutputStream::new, (temporary, destination) -> {
            // Android/Linux rename replaces atomically. The host-test adapter
            // uses Windows' atomic replacement primitive instead.
            if (!temporary.renameTo(destination)) throw new IOException("Cannot replace " + destination);
        });
    }

    BleRawJournal(File filesDir, int capacity, SinkFactory sinkFactory, Replacer replacer) {
        this.capacity = capacity;
        this.queue = new ArrayBlockingQueue<>(capacity);
        this.sinkFactory = sinkFactory;
        this.replacer = replacer;
        root = new File(filesDir, "ble_native_trace");
        directory = new File(root, "run_" + System.currentTimeMillis() + "_" + System.nanoTime());
        stopFile = new File(filesDir, "ble_trace_stop");
        worker = new Thread(this::run, "can-ble-raw-writer");
        worker.setDaemon(true);
        worker.start();
    }

    synchronized long begin() {
        return stopping || finished ? 0 : observed.incrementAndGet();
    }

    boolean isAccepting() { return !stopping && !finished; }

    void record(String immutableJson, boolean originalChanged) {
        if (originalChanged) originalChanges.incrementAndGet();
        synchronized (this) {
            dispatched.incrementAndGet();
            if (finished || !queue.offer(immutableJson)) {
                dropped.incrementAndGet();
            } else {
                enqueued.incrementAndGet();
            }
        }
    }

    void abandon() {
        dispatched.incrementAndGet();
        dropped.incrementAndGet();
    }

    synchronized void closeAsync() {
        if (!stopping) {
            stopping = true;
            closeRequestedNanos = System.nanoTime();
        }
    }

    // Used by tests only; Android lifecycle never joins the worker/UI thread.
    boolean awaitClosed(long milliseconds) throws InterruptedException {
        worker.join(milliseconds);
        return !worker.isAlive();
    }
    File directory() { return directory; }

    private void run() {
        String state = "active";
        try {
            if (!directory.mkdirs()) throw new IOException("Cannot create " + directory);
            writeAtomic(new File(root, "latest.txt"), directory.getName());
            try (OutputStream stream = sinkFactory.open(new File(directory, "notifications.jsonl"));
                 BufferedWriter output = new BufferedWriter(new OutputStreamWriter(stream, StandardCharsets.UTF_8))) {
                long lastFlush = 0;
                while (true) {
                    // ADB control is checked here, never in a BLE callback.
                    if (stopFile.isFile()) closeAsync();
                    String next = queue.poll(100, TimeUnit.MILLISECONDS);
                    if (next != null) {
                        output.write(next);
                        output.newLine();
                        written.incrementAndGet();
                    }
                    long now = System.nanoTime();
                    if (now - lastFlush >= TimeUnit.SECONDS.toNanos(1)) {
                        output.flush();
                        if (stream instanceof FileOutputStream) ((FileOutputStream) stream).getFD().sync();
                        flushed = written.get();
                        manifest("active");
                        lastFlush = now;
                    }
                    synchronized (this) {
                        if (stopping && queue.isEmpty() &&
                            (observed.get() == dispatched.get() ||
                             now - closeRequestedNanos > TimeUnit.SECONDS.toNanos(3))) {
                            finished = true;
                            break;
                        }
                    }
                }
                output.flush();
                if (stream instanceof FileOutputStream) ((FileOutputStream) stream).getFD().sync();
                flushed = written.get();
            }
            state = observed.get() == dispatched.get() ? "closed" : "closed_with_pending_callbacks";
        } catch (Exception error) {
            writeErrors.incrementAndGet();
            failure = error.toString();
            state = "error";
        } finally {
            synchronized (this) {
                finished = true;
                stopping = true;
            }
            // enqueued-written remains explicit if I/O failed; never pretend
            // queued/partially written records were successfully persisted.
            try { manifest(state); }
            catch (IOException error) {
                writeErrors.incrementAndGet();
                failure = error.toString();
                System.err.println("CAN BLE raw journal manifest failed: " + error);
            }
        }
    }

    private void manifest(String status) throws IOException {
        String value;
        synchronized (this) {
            value = "{\"schemaVersion\":1,\"bridgePatch\":\"snapshot-v1\",\"upstreamAndroidPlugin\":\"7.0.4\"," +
                "\"status\":" + quote(status) + ",\"queueCapacity\":" + capacity +
                ",\"observedCallbacks\":" + observed.get() + ",\"dispatchedCallbacks\":" + dispatched.get() +
                ",\"enqueuedRecords\":" + enqueued.get() + ",\"writtenRecords\":" + written.get() +
                ",\"flushedRecords\":" + flushed + ",\"droppedRecords\":" + dropped.get() +
                ",\"writeErrors\":" + writeErrors.get() + ",\"pendingRecords\":" + queue.size() +
                ",\"undispatchedCallbacks\":" + (observed.get() - dispatched.get()) +
                ",\"originalChanges\":" + originalChanges.get() + ",\"failure\":" + quote(failure) +
                ",\"durability\":\"Force-stop can lose in-flight callbacks and the unflushed tail; active manifests are checkpoints\"}";
        }
        writeAtomic(new File(directory, "manifest.json"), value);
    }

    private void writeAtomic(File destination, String value) throws IOException {
        File temporary = new File(destination.getPath() + ".tmp");
        try (FileOutputStream output = new FileOutputStream(temporary)) {
            output.write(value.getBytes(StandardCharsets.UTF_8));
            output.getFD().sync();
        }
        replacer.replace(temporary, destination);
    }

    static String quote(String value) {
        if (value == null) return "null";
        StringBuilder result = new StringBuilder("\"");
        for (char ch : value.toCharArray()) {
            if (ch == '\\' || ch == '"') result.append('\\').append(ch);
            else if (ch < 32) result.append(String.format("\\u%04x", (int) ch));
            else result.append(ch);
        }
        return result.append('"').toString();
    }
}
