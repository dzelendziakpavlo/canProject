import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../models/can_session.dart';
import '../models/can_session_event.dart';
import 'session_analytics.dart';
import 'session_summary_builder.dart';

class SessionPdfReport {
  static Future<Uint8List> build(CanSession session) async {
    final sessionSummary = SessionSummaryBuilder().build(session);
    final analytics = SessionAnalyticsBuilder().build(session);
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

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context ctx) {
          return [
            pw.Header(
              level: 0,
              child: pw.Text('CAN Session Report: ${session.name}'),
            ),
            pw.SizedBox(height: 8),
            pw.Table.fromTextArray(
              data: summaryRows.entries.map((e) => [e.key, e.value]).toList(),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 12),
            pw.Text(
              'Error breakdown',
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 8),
            pw.Table.fromTextArray(
              headers: ['Error Type', 'Count'],
              data: analytics.errorStats.entries
                  .map(
                    (e) => [
                      e.key.toString().split('.').last,
                      e.value.toString(),
                    ],
                  )
                  .toList(),
            ),
            pw.SizedBox(height: 12),
            pw.Text(
              'Top IDs by error percentage',
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 8),
            pw.Table.fromTextArray(
              headers: ['ID', 'Total frames', 'Error frames', 'Error %'],
              data: analytics.errorsPerId
                  .map(
                    (idStat) => [
                      '0x${idStat.id.toRadixString(16).toUpperCase()}',
                      idStat.totalFrames.toString(),
                      idStat.errorFrames.toString(),
                      idStat.percent.toStringAsFixed(1),
                    ],
                  )
                  .toList(),
            ),
            pw.SizedBox(height: 12),
            pw.Text(
              'Top CAN IDs',
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 8),
            pw.Table.fromTextArray(
              headers: ['ID', 'Frames'],
              data: sessionSummary.topCanIds
                  .map((entry) => [entry.formattedId, entry.count.toString()])
                  .toList(),
            ),
            if (session.events.any(
              (event) => event.type == CanSessionEventType.diagnostic,
            )) ...[
              pw.SizedBox(height: 12),
              pw.Text(
                'Diagnostic events',
                style: pw.TextStyle(
                  fontSize: 14,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 8),
              pw.Table.fromTextArray(
                headers: ['Time', 'Severity', 'Cause', 'Message'],
                data: session.events
                    .where(
                      (event) => event.type == CanSessionEventType.diagnostic,
                    )
                    .map(
                      (event) => [
                        event.timestamp.toIso8601String(),
                        event.diagnosticSeverity.name,
                        event.diagnosticCause.name,
                        event.message,
                      ],
                    )
                    .toList(),
              ),
            ],
          ];
        },
      ),
    );

    return doc.save();
  }
}
