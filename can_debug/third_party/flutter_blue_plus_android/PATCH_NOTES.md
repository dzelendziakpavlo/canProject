# CAN Debug Pro local Android bridge patch

Upstream: `flutter_blue_plus_android 7.0.4`, consumed by
`flutter_blue_plus 1.36.8`. The upstream LICENSE and all ten distributed
source/package files are retained. `UPSTREAM_SHA256.json` records their
unmodified hashes. Only `android/build.gradle` (JUnit dependency) and
`FlutterBluePlusPlugin.java` differ among those files; new Java helpers/tests
are additional files. The Dart platform implementation is unchanged.

The root pubspec dependency override pins this directory, and pubspec.lock
records a relative path. Do not apply edits only to the global Pub cache.

Both API 33+ value callbacks and legacy `characteristic.getValue()` callbacks
clone bytes at entry. Legacy callbacks no longer delegate to API 33 methods,
so trace records identify the overload actually invoked. Null values and GATT
status handling remain compatible. MethodChannel receives only owned snapshots.

The opt-in native trace retains an upstream array reference solely until its
UI runnable performs one comparison with the entry snapshot. That reference
is then cleared. A cloned dispatch-time value is used for comparison/hash
consistency. Neither original array nor any byte[] enters the disk queue:
it contains immutable JSON strings only. With tracing disabled, no upstream
array is retained. If a runnable cannot be posted, the reference is released
and the record is counted as dropped. Pending callbacks at shutdown are explicit.

Native tracing is enabled on engine start by private `files/ble_trace_enabled`.
The worker polls `files/ble_trace_stop` to close and flush independently of
Flutter engine shutdown. Only FF10 / FF11 / FF12 are journaled. No new public
receiver, permission, wire field or Flutter plugin method is introduced.

One worker owns disk I/O, including directory creation, manifests, flush/sync
and close. Queue capacity is 1024; producer uses offer without waiting on I/O.
Overflow counts droppedRecords and never drops the MethodChannel event.
Write errors stop diagnostics, remain visible, and do not stop BLE delivery.
The journal is unbounded on disk until stop; only its in-memory queue is bounded.
It is independent of the UI buffer and SQLite.

Manifest checkpoints occur about once per second; force-stop is not a clean
trace close. `writtenRecords` may include buffered writes; `flushedRecords`
advances only after flush and file descriptor sync. On write failure,
enqueued/written/flushed counters retain the distinction. A final manifest
write can itself fail; stderr reports it and the last checkpoint must not be
treated as a complete run. The worker waits up to three seconds for already
observed UI callbacks at close, then reports closed_with_pending_callbacks.

Android uses atomic same-filesystem rename for manifests. Host JVM tests
inject Windows' atomic replacement primitive through the filesystem adapter;
no API 26 java.nio dependency is added to the Android production code.

Run the experiment as described in `../../ANDROID_BLE_NATIVE_EXPERIMENT.md`.
Mutation is a hypothesis until actual probe evidence is captured. A synthetic
mutation test proves snapshot isolation, not a defect in Android or ESP32.
