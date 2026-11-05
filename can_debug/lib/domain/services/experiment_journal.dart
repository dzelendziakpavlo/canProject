import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// Independent append-only capture, never fed from the monitor's display buffer.
/// Async file writes + a bounded queue. On disk failure/overflow capture stops
/// visibly instead of silently claiming a complete experimental recording.
class ExperimentJournal {
  ExperimentJournal._(
    this.directory,
    this._csv,
    this._jsonl,
    this.metadata,
    this.maxPendingRecords,
    this.onFailure,
  );

  static const columns = [
    'hostReceivedAt',
    'espTimestamp',
    'source',
    'type',
    'seq',
    'frameId',
    'dlc',
    'data',
    'rtr',
    'extd',
    'txErrorCounter',
    'rxErrorCounter',
    'busState',
    'busErrorCount',
    'rxTotal',
    'rxMissed',
    'rxOverrunCount',
    'serialParseErrors',
    'serialErrors',
    'sequenceGaps',
    'serialdrop',
    'bledrop',
    'queuedrop',
    'toolong',
    'serialstatdrop',
    'blestatdrop',
    'statdrop',
    'rawJson',
    'error',
  ];

  final Directory directory;
  final RandomAccessFile _csv;
  final RandomAccessFile _jsonl;
  final Map<String, dynamic> metadata;
  final int maxPendingRecords;
  final void Function(Object)? onFailure;
  final Queue<Map<String, dynamic>> _pending = Queue();
  Future<void>? _writing;
  Future<void>? _closing;
  bool _accepting = true;
  Object? failure;
  int writtenRecords = 0;
  int acceptedRecords = 0;
  int unrecordedRecords = 0;

  String get csvPath => '${directory.path}/capture.csv';
  String get jsonlPath => '${directory.path}/capture.jsonl';

  static Future<ExperimentJournal> open(
    Directory base, {
    required Map<String, dynamic> metadata,
    int maxPendingRecords = 8192,
    void Function(Object)? onFailure,
  }) async {
    if (maxPendingRecords < 1) throw ArgumentError.value(maxPendingRecords);
    await base.create(recursive: true);
    final dir = await base.createTemp(
      'capture_${DateTime.now().toUtc().microsecondsSinceEpoch}_',
    );
    final csv = await File(
      '${dir.path}/capture.csv',
    ).open(mode: FileMode.writeOnly);
    RandomAccessFile? jsonl;
    try {
      jsonl = await File(
        '${dir.path}/capture.jsonl',
      ).open(mode: FileMode.writeOnly);
      await csv.writeString('${columns.join(',')}\r\n');
      final journal = ExperimentJournal._(
        dir,
        csv,
        jsonl,
        Map.of(metadata),
        maxPendingRecords,
        onFailure,
      );
      await journal._manifest('recording');
      return journal;
    } catch (_) {
      await csv.close();
      await jsonl?.close();
      rethrow;
    }
  }

  void append(Map<String, dynamic> record) {
    if (!_accepting || failure != null) {
      throw StateError('Journal is closed or failed: $failure');
    }
    if (_pending.length >= maxPendingRecords) {
      unrecordedRecords++;
      final error = StateError(
        'Experimental journal queue full ($maxPendingRecords records)',
      );
      _fail(error);
      throw error;
    }
    _pending.add(Map.of(record));
    acceptedRecords++;
    _kick();
  }

  void _kick() {
    if (_writing != null || failure != null || _pending.isEmpty) return;
    _writing = _drain()
        .catchError((Object error) {
          _fail(error);
        })
        .whenComplete(() {
          _writing = null;
          if (_pending.isNotEmpty && failure == null) _kick();
        });
  }

  Future<void> _drain() async {
    while (_pending.isNotEmpty) {
      final batch = <Map<String, dynamic>>[];
      while (batch.length < 128 && _pending.isNotEmpty) {
        batch.add(_pending.removeFirst());
      }
      final jsonBuffer = StringBuffer();
      final csvBuffer = StringBuffer();
      for (final row in batch) {
        jsonBuffer.writeln(jsonEncode(row));
        csvBuffer.write(columns.map((key) => _escape(row[key])).join(','));
        csvBuffer.write('\r\n');
      }
      await _jsonl.writeString(jsonBuffer.toString());
      await _csv.writeString(csvBuffer.toString());
      writtenRecords += batch.length;
      // Bounded durability interval: every batch is flushed, including stats-only traffic.
      await _jsonl.flush();
      await _csv.flush();
    }
  }

  void _fail(Object error) {
    if (failure != null) return;
    failure = error;
    _accepting = false;
    onFailure?.call(error);
  }

  static String _escape(Object? value) {
    if (value == null) return '';
    final text = value is List || value is Map
        ? jsonEncode(value)
        : value.toString();
    return '"${text.replaceAll('"', '""')}"';
  }

  Future<void> _manifest(
    String status,
  ) => File('${directory.path}/manifest.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      ...metadata,
      'csvPath': csvPath,
      'jsonlPath': jsonlPath,
      'status': status,
      'acceptedRecords': acceptedRecords,
      'writtenRecords': writtenRecords,
      'unrecordedRecords': unrecordedRecords + acceptedRecords - writtenRecords,
      'failure': failure?.toString(),
      'clockNote':
          'ESP millis and host UTC are different clocks; their difference is not latency.',
    }),
    flush: true,
  );

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _accepting = false;
    while (_writing != null) {
      await _writing;
    }
    try {
      await _jsonl.close();
    } catch (e) {
      _fail(e);
    }
    try {
      await _csv.close();
    } catch (e) {
      _fail(e);
    }
    await _manifest(failure == null ? 'closed' : 'incomplete');
    _pending.clear();
  }
}
