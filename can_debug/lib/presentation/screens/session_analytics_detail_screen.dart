import 'package:flutter/material.dart';

import 'dart:io';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'package:file_selector/file_selector.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import '../../core/theme.dart';
import '../../domain/models/can_frame.dart';
import '../../domain/detection/can_error_checker.dart';
import '../../domain/models/can_session.dart';
import '../../domain/models/can_session_event.dart';
import '../../domain/models/can_session_summary.dart';
import '../../domain/services/can_session_service.dart';
import '../../domain/services/session_comparison.dart';
import '../../domain/services/session_analytics.dart';
import '../widgets/session_analytics_widgets.dart';
import '../widgets/professional_charts.dart';
import 'replay_screen.dart';

class SessionAnalyticsDetailScreen extends StatefulWidget {
  final CanSession session;
  const SessionAnalyticsDetailScreen({super.key, required this.session});

  @override
  State<SessionAnalyticsDetailScreen> createState() => _SessionAnalyticsDetailScreenState();
}

class _SessionAnalyticsDetailScreenState extends State<SessionAnalyticsDetailScreen> {
  late final SessionAnalyticsBuilder _builder;
  late final SessionComparisonBuilder _comparisonBuilder;
  late CanSessionSummary _summary;
  late SessionAnalyticsData _data;
  late CanSession _exportSession;
  final _checker = CanErrorChecker();

  // Filters
  DateTimeRange? _timeRange;
  int? _idMin;
  int? _idMax;
  final Set<CanErrorType> _selectedErrorTypes = {};
  int _minSeverity = 1;

  // For formatting filenames
  final _dateFmt = DateFormat('yyyyMMdd_HHmmss');

  // Comparison state
  CanSession? _compareSession;
  SessionAnalyticsData? _compareData;
  bool _isComparing = false;

  @override
  void initState() {
    super.initState();
    _builder = SessionAnalyticsBuilder();
    _comparisonBuilder = SessionComparisonBuilder();
    _exportSession = widget.session;
    _summary = CanSessionService.instance.buildSessionSummary(widget.session);
    _data = _builder.build(widget.session);
  }

  void _applyFilters() {
    final session = widget.session;
    List<CanFrame> frames = session.frames;

    if (_timeRange != null) {
      frames = frames.where((f) => !f.timestamp.isBefore(_timeRange!.start) && !f.timestamp.isAfter(_timeRange!.end)).toList();
    }

    if (_idMin != null) {
      frames = frames.where((f) => f.id >= _idMin!).toList();
    }
    if (_idMax != null) {
      frames = frames.where((f) => f.id <= _idMax!).toList();
    }

    // Filter by error types and severity
    frames = frames.where((f) {
      final errors = _checker.analyzeFrame(f);
      if (_selectedErrorTypes.isNotEmpty) {
        if (errors.every((e) => !_selectedErrorTypes.contains(e.type))) return false;
      }
      if (_minSeverity > 1) {
        // Keep only frames that have at least one error meeting severity
        if (errors.where((e) => e.severity >= _minSeverity).isEmpty) return false;
      }
      return true;
    }).toList();

    final totalFrames = frames.length;
    final errorFrames = frames.where((f) => _checker.hasError(f)).length;
    final errorRate = totalFrames == 0 ? 0.0 : (errorFrames / totalFrames) * 100.0;

    final filteredSession = session.updateWith(
      frames: frames,
      totalFrames: totalFrames,
      errorFrames: errorFrames,
      errorRate: errorRate,
    );

    setState(() {
      _exportSession = filteredSession;
      _summary = CanSessionService.instance.buildSessionSummary(filteredSession);
      _data = _builder.build(filteredSession);
    });
  }

  Future<void> _exportCsv() async {
    final session = _exportSession;
    final filename = '${session.name.replaceAll(' ', '_')}_${_dateFmt.format(DateTime.now())}.csv';

    final header = 'timestamp,id,dlc,data_hex,crc,is_corrupted,error_count,errors,error_origins,severity\n';
    final buffer = StringBuffer();
    buffer.write(header);

    for (final f in session.frames) {
      final errors = _checker.analyzeFrame(f);
      final errJson = errors.map((e) => '${e.type.toString().split('.').last}:${e.severity}').join('|');
      final origins = errors.map((e) => e.origin.name).join('|');
      final maxSeverity = errors.isEmpty ? 0 : errors.map((e) => e.severity).reduce((a, b) => a > b ? a : b);
      buffer.write('"${f.timestamp.toIso8601String()}",${f.id},${f.dlc},"${f.dataHex}",${f.crc},${f.isCorrupted},${errors.length},"${errJson}","${origins}",${maxSeverity}\n');
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$filename');
      await file.writeAsString(buffer.toString());
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('CSV exported: ${file.path}')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('CSV export failed: $e')));
    }
  }

  Future<void> _exportJson() async {
    final session = _exportSession;
    final export = <String, dynamic>{
      'format': 'can-debug-session-export',
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'session': session.toJson(),
      'summary': _summary.toJson(),
      'analytics': {
        'errorStats': _data.errorStats.map((key, value) => MapEntry(key.name, value)),
        'recommendations': _data.recommendations,
        'errorsPerId': _data.errorsPerId
            .map((entry) => {
                  'id': entry.id,
                  'totalFrames': entry.totalFrames,
                  'errorFrames': entry.errorFrames,
                  'errorRate': entry.percent,
                })
            .toList(),
      },
      'diagnostics': session.events
          .where((event) => event.type == CanSessionEventType.diagnostic)
          .map((event) => event.toJson())
          .toList(),
    };

    try {
      final dir = await getApplicationDocumentsDirectory();
      final filename = '${session.name.replaceAll(' ', '_')}_${_dateFmt.format(DateTime.now())}.json';
      final file = File('${dir.path}/$filename');
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(export));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('JSON exported: ${file.path}')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('JSON export failed: $e')));
    }
  }

  Future<void> _exportPdf() async {
    final session = _exportSession;
    final sessionSummary = _summary;
    final doc = pw.Document();

    final summaryRows = <String, String>{
      'Session': sessionSummary.sessionName,
      'Start': sessionSummary.startTime.toIso8601String(),
      'End': sessionSummary.endTime?.toIso8601String() ?? 'ongoing',
      'Duration': sessionSummary.duration.toString().split('.').first,
      'Total frames': sessionSummary.totalFrames.toString(),
      'Error frames': sessionSummary.errorFrames.toString(),
      'Error rate': '${sessionSummary.errorRate.toStringAsFixed(2)}%',
      'Health score': '${sessionSummary.healthScore}/100',
      'Severity': sessionSummary.severity.displayName,
    };

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      build: (pw.Context ctx) {
        return [
          pw.Header(level: 0, child: pw.Text('CAN Session Report: ${session.name}')),
          pw.SizedBox(height: 8),
          pw.Table.fromTextArray(
            data: summaryRows.entries.map((e) => [e.key, e.value]).toList(),
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 12),
          pw.Text('Error breakdown', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 8),
          pw.Table.fromTextArray(
            headers: ['Error Type', 'Count'],
            data: _data.errorStats.entries.map((e) => [e.key.toString().split('.').last, e.value.toString()]).toList(),
          ),
          pw.SizedBox(height: 12),
          pw.Text('Top IDs by error percentage', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 8),
          pw.Table.fromTextArray(
            headers: ['ID', 'Total frames', 'Error frames', 'Error %'],
            data: _data.errorsPerId.map((idStat) => [
              '0x${idStat.id.toRadixString(16).toUpperCase()}',
              idStat.totalFrames.toString(),
              idStat.errorFrames.toString(),
              idStat.percent.toStringAsFixed(1)
            ]).toList(),
          ),
          pw.SizedBox(height: 12),
          pw.Text('Top CAN IDs', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 8),
          pw.Table.fromTextArray(
            headers: ['ID', 'Frames'],
            data: sessionSummary.topCanIds
                .map((entry) => [entry.formattedId, entry.count.toString()])
                .toList(),
          ),
          if (session.events.any((event) => event.type == CanSessionEventType.diagnostic)) ...[
            pw.SizedBox(height: 12),
            pw.Text('Diagnostic events', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 8),
            pw.Table.fromTextArray(
              headers: ['Time', 'Severity', 'Cause', 'Message'],
              data: session.events
                  .where((event) => event.type == CanSessionEventType.diagnostic)
                  .map((event) => [
                        event.timestamp.toIso8601String(),
                        event.diagnosticSeverity.name,
                        event.diagnosticCause.name,
                        event.message,
                      ])
                  .toList(),
            ),
          ],
        ];
      },
    ));

    try {
      final bytes = await doc.save();
      final dir = await getApplicationDocumentsDirectory();
      final filename = '${session.name.replaceAll(' ', '_')}_${_dateFmt.format(DateTime.now())}.pdf';
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(bytes);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF exported: ${file.path}')));
      // Optionally preview/print
      // await Printing.layoutPdf(onLayout: (format) => bytes);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF export failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;

    return Scaffold(
      backgroundColor: AppTheme.darkBackground,
      appBar: AppBar(
        backgroundColor: AppTheme.darkSurface,
        title: Text('Session: ${session.name}'),
        foregroundColor: AppTheme.textPrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(_summary),
            const SizedBox(height: 12),
            _buildSummaryPanel(_summary),
            if (_isComparing && _compareData != null) ...[
              const SizedBox(height: 12),
              _buildComparisonPanel(),
            ],
            const SizedBox(height: 12),

            // Row 1: Pie + Error Over Time
            _TwoColumns(
              left: ErrorTypeDistributionChart(
                errorStats: _data.errorStats,
                height: 150,
                onSliceTap: (type) => showErrorTypeDetailsSheet(context, widget.session, type, builder: _builder),
              ),
              right: ErrorOverTimeChart(points: _data.errorsOverTime),
            ),

            const SizedBox(height: 12),

            // Row 2: Bit Error Ratio + Errors per ID
            _TwoColumns(
              left: BitErrorRatioChart(points: _data.bitErrorRatioOverTime),
              right: ErrorsPerIdBarChart(stats: _data.errorsPerId),
            ),

            const SizedBox(height: 12),
            ErrorHeatmap(data: _data.heatmap),

            const SizedBox(height: 16),
            _buildRecommendations(),

            const SizedBox(height: 16),
            _buildDiagnosticEvents(),

            const SizedBox(height: 16),
            _buildErrorTypeActions(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(CanSessionSummary summary) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.darkContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(gradient: _getSeverityGradient(summary.severity), shape: BoxShape.circle),
            child: const Icon(Icons.analytics, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(summary.sessionName, style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('${summary.duration.toString().split('.').first} • ${summary.totalFrames} frames • ${summary.errorRate.toStringAsFixed(1)}% errors', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
              ],
            ),
          ),
          Flexible(
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _getSeverityColor(summary.severity).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _getSeverityColor(summary.severity).withOpacity(0.3)),
                  ),
                  child: Text(
                    summary.severity.displayName,
                    style: TextStyle(color: _getSeverityColor(summary.severity), fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () async {
                    // open filter editor dialog
                    await showDialog<void>(
                      context: context,
                      builder: (c) => _FilterDialog(
                        initialRange: _timeRange,
                        idMin: _idMin,
                        idMax: _idMax,
                        selectedTypes: Set.from(_selectedErrorTypes),
                        minSeverity: _minSeverity,
                        onApply: (range, minId, maxId, types, minSev) {
                          _timeRange = range;
                          _idMin = minId;
                          _idMax = maxId;
                          _selectedErrorTypes
                            ..clear()
                            ..addAll(types);
                          _minSeverity = minSev;
                          _applyFilters();
                        },
                      ),
                    );
                  },
                  icon: const Icon(Icons.filter_list),
                  label: const Text('Filters'),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryOrange),
                ),
                ElevatedButton.icon(
                  onPressed: _exportCsv,
                  icon: const Icon(Icons.file_download),
                  label: const Text('Export CSV'),
                ),
                ElevatedButton.icon(
                  onPressed: _exportJson,
                  icon: const Icon(Icons.data_object),
                  label: const Text('Export JSON'),
                ),
                ElevatedButton.icon(
                  onPressed: _exportPdf,
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('Export PDF'),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentGreen),
                ),
                ElevatedButton.icon(
                  onPressed: _importSession,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Import'),
                ),
                ElevatedButton.icon(
                  onPressed: _openComparePicker,
                  icon: const Icon(Icons.compare_arrows),
                  label: Text(_isComparing ? 'Comparing' : 'Compare'),
                ),
                ElevatedButton.icon(
                  onPressed: _summary.hasReplayableData
                      ? () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => ReplayScreen(session: widget.session)),
                          )
                      : null,
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Replay'),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryAmber),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryPanel(CanSessionSummary summary) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.darkContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.summarize, color: AppTheme.primaryAmber, size: 20),
              const SizedBox(width: 8),
              const Text('Session Summary', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold)),
              const Spacer(),
              _summaryChip('Health ${summary.healthScore}/100'),
              const SizedBox(width: 8),
              _summaryChip(summary.severity.displayName),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _summaryStat('Mode', summary.monitorMode),
              _summaryStat('Source', summary.sourceName ?? 'n/a'),
              _summaryStat('Bus State', summary.latestBusState ?? 'n/a'),
              _summaryStat('Events', summary.totalEvents.toString()),
              _summaryStat('Batches', summary.frameBatchEvents.toString()),
              _summaryStat('Errors', summary.errorDetectedEvents.toString()),
              _summaryStat('Diagnostics', summary.diagnosticEvents.toString()),
              _summaryStat('Reconnects', summary.reconnectCount.toString()),
              _summaryStat('Stats Snapshots', summary.statsSnapshotsCount.toString()),
              _summaryStat('Duration', summary.duration.toString().split('.').first),
              _summaryStat('Error Rate', '${summary.errorRate.toStringAsFixed(1)}%'),
              _summaryStat('TEC', summary.latestTxErrorCounter?.toString() ?? 'n/a'),
              _summaryStat('REC', summary.latestRxErrorCounter?.toString() ?? 'n/a'),
              _summaryStat('RX Total', summary.latestRxTotal?.toString() ?? 'n/a'),
              _summaryStat('Bus Errors', summary.latestBusErrorCount?.toString() ?? 'n/a'),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Last frame: ${summary.lastFrameTimestamp?.toIso8601String() ?? 'n/a'}',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          Text(
            'Last stats: ${summary.lastStatsTimestamp?.toIso8601String() ?? 'n/a'}',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          Text(
            'Latest flags: busOff=${summary.latestIsBusOff}, recovering=${summary.latestIsRecovering}, passive=${summary.latestIsErrorPassive}, warning=${summary.latestIsErrorWarning}, noAck=${summary.latestIsNoAckMode}, speedMismatch=${summary.latestIsSpeedMismatchDemo}',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          if (summary.topCanIds.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Top CAN IDs', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: summary.topCanIds
                  .map((entry) => _summaryChip('${entry.formattedId} • ${entry.count}'))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _summaryStat(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.darkBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _summaryChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.primaryOrange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppTheme.primaryOrange.withValues(alpha: 0.3)),
      ),
      child: Text(text, style: const TextStyle(color: AppTheme.primaryOrange, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }

  void _openComparePicker() async {
    final svc = CanSessionService.instance;
    final sessions = svc.savedSessions.where((s) => s.id != widget.session.id).toList();
    if (sessions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No other sessions available to compare')));
      return;
    }

    final picked = await showModalBottomSheet<CanSession>(
      context: context,
      builder: (c) => ListView(
        shrinkWrap: true,
        children: sessions.map((s) => ListTile(
          title: Text(s.name),
          subtitle: Text('${s.formattedDuration} • ${s.totalFrames} frames • ${s.errorRate.toStringAsFixed(1)}%'),
          onTap: () => Navigator.of(c).pop(s),
        )).toList(),
      ),
    );

    if (picked != null) {
      _startComparison(picked);
    }
  }

  void _startComparison(CanSession other) {
    final otherData = _builder.build(other);
    setState(() {
      _compareSession = other;
      _compareData = otherData;
      _isComparing = true;
    });
  }

  Future<void> _importSession() async {
    try {
      // Use file_selector to open a single or multiple JSON files
      final typeGroup = XTypeGroup(label: 'json', extensions: ['json']);
      final files = await openFiles(acceptedTypeGroups: [typeGroup]);
      if (files.isEmpty) return;
      // Process first file or all files
      int importedCount = 0;
      final svc = CanSessionService.instance;
      for (final xf in files) {
        final content = await File(xf.path).readAsString();
        final decoded = jsonDecode(content);

        if (decoded is Map<String, dynamic>) {
          final session = CanSession.fromJson(decoded);
          await svc.addImportedSession(session);
          importedCount++;
        } else if (decoded is List) {
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              final session = CanSession.fromJson(item);
              await svc.addImportedSession(session);
              importedCount++;
            }
          }
        }
      }
      if (importedCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Imported $importedCount session(s)')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No valid sessions found in selected files')));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }

  Widget _buildComparisonPanel() {
    if (_compareData == null) return const SizedBox.shrink();
    final base = _data;
    final other = _compareData!;
    final comparison = _comparisonBuilder.build(widget.session, _compareSession!);
    final thisSummary = comparison.thisSummary;
    final otherSummary = comparison.otherSummary;

  // compute simple deltas on main counts (used in rows below if needed)

    Widget _metricRow(String label, String a, String b) {
      final ad = double.tryParse(a.replaceAll('%', '')) ?? 0.0;
      final bd = double.tryParse(b.replaceAll('%', '')) ?? 0.0;
      final delta = bd - ad;
      final deltaText = delta >= 0 ? '+${delta.toStringAsFixed(1)}' : delta.toStringAsFixed(1);
      return Row(children: [Expanded(child: Text(label)), Text(a), const SizedBox(width: 12), Text(b), const SizedBox(width: 12), Text(deltaText)]);
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppTheme.darkContainer, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text('Comparing with: ${_compareSession!.name}', style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold))),
            TextButton(onPressed: () => setState(() { _isComparing = false; _compareSession = null; _compareData = null; }), child: const Text('Clear'))
          ]),
          const SizedBox(height: 8),
          // Summary metrics
          Row(children: [Expanded(child: Text('Metric')), const SizedBox(width: 8), Text('This'), const SizedBox(width: 12), Text('Other'), const SizedBox(width: 12), Text('Δ')]),
          const Divider(),
          _metricRow('Total frames', '${thisSummary.totalFrames}', '${otherSummary.totalFrames}'),
          const SizedBox(height: 6),
          _metricRow('Error frames', '${thisSummary.errorFrames}', '${otherSummary.errorFrames}'),
          const SizedBox(height: 6),
          _metricRow('Error rate', '${thisSummary.errorRate.toStringAsFixed(2)}%', '${otherSummary.errorRate.toStringAsFixed(2)}%'),
          const SizedBox(height: 6),
          _metricRow('Health score', '${thisSummary.healthScore}', '${otherSummary.healthScore}'),
          const SizedBox(height: 6),
          _metricRow('Reconnects', '${thisSummary.reconnectCount}', '${otherSummary.reconnectCount}'),
          const SizedBox(height: 12),
          SizedBox(
            height: 120,
            child: CustomPaint(
              painter: _CombinedErrorOverTimePainter(base.errorsOverTime, other.errorsOverTime),
              size: Size(double.infinity, 120),
            ),
          ),
          if (comparison.idComparisons.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Changed CAN IDs', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            ...comparison.idComparisons.take(8).map((entry) {
              final delta = entry.delta;
              final color = delta > 0 ? AppTheme.accentRed : AppTheme.accentGreen;
              final deltaText = delta > 0 ? '+$delta' : '$delta';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(child: Text(entry.formattedId, style: const TextStyle(color: AppTheme.textSecondary, fontFamily: 'monospace'))),
                    Text('${entry.thisCount}', style: const TextStyle(color: AppTheme.textSecondary)),
                    const SizedBox(width: 12),
                    Text('${entry.otherCount}', style: const TextStyle(color: AppTheme.textSecondary)),
                    const SizedBox(width: 12),
                    Text(deltaText, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildRecommendations() {
    final recs = _data.recommendations;
    if (recs.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppTheme.darkContainer, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.lightbulb, color: AppTheme.primaryOrange),
              SizedBox(width: 8),
              Text('Recommendations', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          ...recs.map((r) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Icon(Icons.check, color: AppTheme.accentGreen, size: 16),
                    const SizedBox(width: 8),
                    Expanded(child: Text(r, style: const TextStyle(color: AppTheme.textSecondary))),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildDiagnosticEvents() {
    final events = widget.session.events
        .where((event) => event.type == CanSessionEventType.diagnostic)
        .toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (events.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.darkContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.warning_amber, color: AppTheme.primaryAmber),
              SizedBox(width: 8),
              Text('Diagnostic Events', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 10),
          ...events.map(_buildDiagnosticEvent),
        ],
      ),
    );
  }

  Widget _buildDiagnosticEvent(CanSessionEvent event) {
    final color = _diagnosticColor(event.diagnosticSeverity);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(event.message, style: TextStyle(color: color, fontWeight: FontWeight.bold))),
              Text(event.diagnosticSeverity.name.toUpperCase(), style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 4),
          Text('${event.timestamp.toIso8601String()} • cause: ${event.diagnosticCause.name}', style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
          if (event.explanation != null) ...[
            const SizedBox(height: 6),
            Text(event.explanation!, style: const TextStyle(color: AppTheme.textSecondary)),
          ],
          if (event.recommendation != null) ...[
            const SizedBox(height: 4),
            Text('Action: ${event.recommendation}', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  Color _diagnosticColor(DiagnosticSeverity severity) {
    switch (severity) {
      case DiagnosticSeverity.info:
        return AppTheme.accentGreen;
      case DiagnosticSeverity.warning:
        return AppTheme.primaryAmber;
      case DiagnosticSeverity.error:
        return AppTheme.primaryOrange;
      case DiagnosticSeverity.critical:
        return AppTheme.accentRed;
    }
  }

  Widget _buildErrorTypeActions() {
    final entries = _data.errorStats.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (entries.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: entries.map((e) {
        return GestureDetector(
          onTap: () => showErrorTypeDetailsSheet(context, widget.session, e.key, builder: _builder),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: AppTheme.darkContainer, borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white12)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: AppTheme.primaryOrange, size: 16),
                const SizedBox(width: 6),
                Text('${_label(e.key)} • ${e.value}', style: const TextStyle(color: AppTheme.textPrimary)),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  String _label(CanErrorType type) {
    switch (type) {
      case CanErrorType.crcError:
        return 'CRC';
      case CanErrorType.stuffingError:
        return 'Stuff';
      case CanErrorType.formatError:
        return 'Format';
      case CanErrorType.ackError:
        return 'ACK';
      case CanErrorType.overloadError:
        return 'Overload';
      case CanErrorType.formError:
        return 'Form';
      default:
        return type.name;
    }
  }

  LinearGradient _getSeverityGradient(SessionSeverity severity) {
    switch (severity) {
      case SessionSeverity.critical:
        return const LinearGradient(colors: [AppTheme.accentRed, Color(0xFFD32F2F)]);
      case SessionSeverity.high:
        return const LinearGradient(colors: [Color(0xFFFF9800), AppTheme.accentRed]);
      case SessionSeverity.medium:
        return const LinearGradient(colors: [AppTheme.primaryOrange, Color(0xFFFF9800)]);
      case SessionSeverity.low:
        return const LinearGradient(colors: [AppTheme.primaryAmber, AppTheme.primaryOrange]);
      case SessionSeverity.normal:
        return const LinearGradient(colors: [AppTheme.accentGreen, Color(0xFF66BB6A)]);
    }
  }

  Color _getSeverityColor(SessionSeverity severity) {
    switch (severity) {
      case SessionSeverity.critical:
        return AppTheme.accentRed;
      case SessionSeverity.high:
        return AppTheme.accentRed;
      case SessionSeverity.medium:
        return AppTheme.primaryOrange;
      case SessionSeverity.low:
        return AppTheme.primaryAmber;
      case SessionSeverity.normal:
        return AppTheme.accentGreen;
    }
  }
}

class _TwoColumns extends StatelessWidget {
  final Widget left;
  final Widget right;
  const _TwoColumns({required this.left, required this.right});
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 800) {
          return Column(children: [left, const SizedBox(height: 12), right]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: left),
            const SizedBox(width: 12),
            Expanded(child: right),
          ],
        );
      },
    );
  }
}

/// Painter that overlays two error-over-time series
class _CombinedErrorOverTimePainter extends CustomPainter {
  final List<TimeBucketPoint> a;
  final List<TimeBucketPoint> b;
  _CombinedErrorOverTimePainter(this.a, this.b);

  @override
  void paint(Canvas canvas, Size size) {
    final paintA = Paint()..color = AppTheme.primaryAmber..strokeWidth = 2..style = PaintingStyle.stroke;
    final paintB = Paint()..color = AppTheme.accentRed..strokeWidth = 2..style = PaintingStyle.stroke;

    final maxCount = [
      if (a.isNotEmpty) a.map((p) => p.count).reduce((x, y) => x > y ? x : y),
      if (b.isNotEmpty) b.map((p) => p.count).reduce((x, y) => x > y ? x : y),
    ].fold<int>(0, (prev, v) => v > prev ? v : prev);

    if (maxCount == 0) return;

    final len = (a.length > b.length) ? a.length : b.length;
    if (len <= 1) return;

    List<Offset> pointsA = [];
    List<Offset> pointsB = [];
    for (int i = 0; i < len; i++) {
      final x = (i / (len - 1)) * size.width;
      final valA = i < a.length ? a[i].count.toDouble() : 0.0;
      final valB = i < b.length ? b[i].count.toDouble() : 0.0;
      final yA = size.height - (valA / maxCount) * size.height;
      final yB = size.height - (valB / maxCount) * size.height;
      pointsA.add(Offset(x, yA));
      pointsB.add(Offset(x, yB));
    }

    final pathA = Path()..moveTo(pointsA.first.dx, pointsA.first.dy);
    for (int i = 1; i < pointsA.length; i++) pathA.lineTo(pointsA[i].dx, pointsA[i].dy);
    canvas.drawPath(pathA, paintA);

    final pathB = Path()..moveTo(pointsB.first.dx, pointsB.first.dy);
    for (int i = 1; i < pointsB.length; i++) pathB.lineTo(pointsB[i].dx, pointsB[i].dy);
    canvas.drawPath(pathB, paintB);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Dialog for editing filters
class _FilterDialog extends StatefulWidget {
  final DateTimeRange? initialRange;
  final int? idMin;
  final int? idMax;
  final Set<CanErrorType> selectedTypes;
  final int minSeverity;
  final void Function(DateTimeRange? range, int? idMin, int? idMax, Set<CanErrorType> types, int minSeverity) onApply;

  const _FilterDialog({
    required this.initialRange,
    required this.idMin,
    required this.idMax,
    required this.selectedTypes,
    required this.minSeverity,
    required this.onApply,
  });

  @override
  State<_FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends State<_FilterDialog> {
  DateTimeRange? _range;
  final _idMinCtrl = TextEditingController();
  final _idMaxCtrl = TextEditingController();
  late Set<CanErrorType> _types;
  late int _minSeverity;

  @override
  void initState() {
    super.initState();
    _range = widget.initialRange;
    if (widget.idMin != null) _idMinCtrl.text = widget.idMin.toString();
    if (widget.idMax != null) _idMaxCtrl.text = widget.idMax.toString();
    _types = Set.from(widget.selectedTypes);
    _minSeverity = widget.minSeverity;
  }

  @override
  void dispose() {
    _idMinCtrl.dispose();
    _idMaxCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.darkSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: AppTheme.primaryOrange.withOpacity(0.3))),
      title: const Text('Filters', style: TextStyle(color: AppTheme.textPrimary)),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Time range', style: TextStyle(color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            Row(children: [
              ElevatedButton(
                onPressed: () async {
                  final picked = await showDateRangePicker(context: context, firstDate: DateTime(2000), lastDate: DateTime.now(), initialDateRange: _range);
                  if (picked != null) setState(() => _range = picked);
                },
                child: Text(_range == null ? 'Select range' : '${_range!.start.toLocal()} - ${_range!.end.toLocal()}'),
              ),
              const SizedBox(width: 8),
              TextButton(onPressed: () => setState(() => _range = null), child: const Text('Clear')),
            ]),
            const SizedBox(height: 12),

            const Text('CAN ID range', style: TextStyle(color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            Row(children: [
              Flexible(child: TextField(controller: _idMinCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: 'Min ID'))),
              const SizedBox(width: 8),
              Flexible(child: TextField(controller: _idMaxCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: 'Max ID'))),
            ]),
            const SizedBox(height: 12),

            const Text('Error types', style: TextStyle(color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: CanErrorType.values.where((t) => t != CanErrorType.none).map((t) {
              final label = t.toString().split('.').last;
              final selected = _types.contains(t);
              return FilterChip(label: Text(label), selected: selected, onSelected: (v) => setState(() => v ? _types.add(t) : _types.remove(t)));
            }).toList()),
            const SizedBox(height: 12),

            const Text('Minimum severity', style: TextStyle(color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            DropdownButton<int>(value: _minSeverity, items: [1,2,3,4,5].map((v) => DropdownMenuItem(value: v, child: Text('$v'))).toList(), onChanged: (v) { if (v!=null) setState(()=>_minSeverity=v); }),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryAmber),
          onPressed: () {
            final minId = int.tryParse(_idMinCtrl.text);
            final maxId = int.tryParse(_idMaxCtrl.text);
            widget.onApply(_range, minId, maxId, _types, _minSeverity);
            Navigator.of(context).pop();
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
