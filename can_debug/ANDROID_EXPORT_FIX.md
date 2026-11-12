# Android export: zero-byte documents

Date: 2026-11-08. Device: Redmi Note 8T, `com.example.can_debug`.

## Observed evidence

The phone contained two **zero-byte** documents in `Download/Schemes can debus/`:

- `Schema_1_1794155869268402_20261108_184144.json`
- `Schema_1_1794155869268402_20261108_184555.csv`

Their complete staged sources still existed in the app cache: 8,350,070 bytes of JSON and 6,224,152 bytes of CSV. The PDF existed in private `app_flutter/Schema_1_20261108_184800.pdf`, 6,299 bytes. PDF had not been integrated with the Android document picker.

The database passed `PRAGMA quick_check` and contained 7,184 frames, 200 stats snapshots and 2,681 events for session `1794155869268402`. Both staged exports contained exactly those record counts. Free storage was about 6 GB, so the observed failure was not an empty session or exhausted disk space.

Logcat recorded the Android low-memory killer terminating `com.example.can_debug` at 18:47:30. The old implementation kept `pendingExport` and its source file reference only in Activity memory. If Android killed/recreated the process while the document picker was open, `onActivityResult` returned immediately because `pendingExport == null`, leaving the provider-created placeholder empty. An Activity result callback must not rely on memory surviving the picker; [Android documents process recreation and state preservation](https://developer.android.com/guide/components/activities/activity-lifecycle). The picker intentionally creates the new document using [`ACTION_CREATE_DOCUMENT`](https://developer.android.com/training/data-storage/shared/documents-files).

## Restored user files

Complete copies were restored to the phone under **new names**; neither the source recordings nor the zero-byte originals were overwritten:

| File in `Download/Schemes can debus/` | Bytes |
|---|---:|
| `Schema_1_1794155869268402_20261108_184144_recovered.json` | 8,350,070 |
| `Schema_1_1794155869268402_20261108_184555_recovered.csv` | 6,224,152 |
| `Schema_1_20261108_184800_recovered.pdf` | 6,299 |

SHA-256 of each phone copy matched its backed-up source. Local evidence and exact hashes: `build/validation/export_recovery_report.json`. These are recovered **real user data**, not synthetic test fixtures.

## Changes

- `SessionFileSaver` stages nonempty payloads in durable private `files/pending_exports/`, with expected byte count and SHA-256. They are not prematurely deleted when the picker/Activity disappears.
- `MainActivity` commits the pending operation to native SharedPreferences **before** opening the picker. The source, destination URI and transfer state survive process death. No Activity-local MethodChannel result is held across the picker. Dart polls durable status.
- `VerifiedExport` validates the staged source, copies with a bounded 64 KiB buffer, closes the destination, reopens it, and compares **actual bytes and SHA-256**. A provider-created zero-byte/corrupt document cannot produce success.
- Destination URI permissions are persisted where the provider supports them. Interrupted writes retry from the beginning using truncate mode. A failed copy retains its staged source and reports an error; cancellation and verified success clean up that operation's staged file.
- `ExportRecoveryNotice` reports a recovered result at Dashboard even if the original Analytics screen no longer exists. An unfinished/failed operation has a Resume action. An unacknowledged completion remains stored until Dart consumes it.
- JSON, CSV and PDF use the same guarded save path and busy state. PDF now opens the system picker too; the whole report generation is covered by error handling.
- CSV metadata no longer constructs and discards another JSON representation of the entire frame/event history, reducing avoidable allocations before the picker opens.

No CAN frames, stats, sessions, firmware or Windows USB wire journals were changed. Old failed cache files were preserved in the backup, not silently deleted.

## Validation

- **87 Flutter tests passed**, including real PDF generation, nonempty JSON/CSV/PDF staging, native receipt byte/hash validation, zero-byte rejection, SQLite/full export counts, navigation and Windows USB regressions.
- **4 Kotlin/JVM tests passed**: 8 MB byte-for-byte transfer, rejection of empty/corrupt source before opening the destination, zero/corrupt provider readback rejection, and retry with a fresh worker using only durable source information.
- Android debug APK built and installed successfully with `adb install -r`, preserving app data.
- `flutter analyze`: no compilation errors; 104 lint findings including the preexisting unused-import warning.
- Physical recovery test began with the real 8,350,070-byte JSON and a saved request at `build/validation/physical_json_export_request.json`. The process was killed while the system picker remained open; a subsequent independent `pidof` returned no process. After Save, Android started a new process (old PID 19844, new PID 22727). USB disconnected before final file verification; this is **not yet recorded as an end-to-end pass**.

Logs: `build/validation/tests_export_fix_full.txt`, `tests_native_export.txt`, `analyze_android_export_fix.txt`, `build_android_export_fix.txt`.

Backups before edits: `.work_backups/android_export_fix_before_20261108_184949.zip` and `.work_backups/android_device_export_before_20261108_184949.tar` (device archive SHA-256 `b33e882913a70b14252b0ceedfcf19a6dad18268e71f67ffa026df5fa4aa7457`).

## Remaining limits

Provider-specific URI grants/readback can fail and are reported rather than treated as success. Force-stop/cancelled task behavior differs from Android reclaiming a background process; explicit Resume remains available for durable pending operations. Generating a very large report still requires Dart memory proportional to its contents; bounded native copying prevents another full in-memory copy during transfer. PDF retains the existing Helvetica font limitations for non-Latin text; this is separate from document size and write integrity.
