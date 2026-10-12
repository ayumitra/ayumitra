import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/services/local_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

Uint8List sparsePdf() {
  const stream =
      'BT /F1 12 Tf 50 750 Td (SYNTHETIC scanned report header) Tj ET';
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
  ];
  var pdf = '%PDF-1.4\n';
  final offsets = <int>[];
  for (final (index, object) in objects.indexed) {
    offsets.add(pdf.length);
    pdf += '${index + 1} 0 obj\n$object\nendobj\n';
  }
  final xref = pdf.length;
  pdf += 'xref\n0 6\n0000000000 65535 f \n';
  for (final offset in offsets) {
    pdf += '${offset.toString().padLeft(10, '0')} 00000 n \n';
  }
  pdf += 'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n';
  return Uint8List.fromList(ascii.encode(pdf));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory scratch;
  setUpAll(() async {
    scratch = await Directory.systemTemp.createTemp('ayumitra-pdf-test-');
    Pdfrx.cacheDirectoryPath = scratch.path;
    var modulePath = Platform.environment['PDFIUM_PATH'];
    if (modulePath == null && Platform.isMacOS) {
      final config = File('.dart_tool/package_config.json');
      final packages =
          (jsonDecode(await config.readAsString()) as Map)['packages'] as List;
      final pdfium = packages.cast<Map>().firstWhere(
        (p) => p['name'] == 'pdfium_flutter',
      );
      final root = Uri.directory(
        config.absolute.uri.resolve(pdfium['rootUri'] as String).toFilePath(),
      );
      modulePath = root
          .resolve(
            'darwin/PDFium.xcframework/macos-arm64_x86_64/PDFium.framework/Versions/A/PDFium',
          )
          .toFilePath();
    }
    if (modulePath == null) {
      throw StateError(
        'These native PDF checks require PDFIUM_PATH on this host.',
      );
    }
    Pdfrx.pdfiumModulePath = modulePath;
    await pdfrxFlutterInitialize();
  });
  tearDownAll(() => scratch.delete(recursive: true));
  final report = Report(
    id: 'r',
    profileId: 'p',
    name: 'SYNTHETIC.pdf',
    extension: 'pdf',
    digest: 'test',
    importedAt: DateTime(2026),
  );

  test(
    'Sparse PDF header invokes vision rather than silently skipping page content',
    () async {
      var calls = 0;
      final parser = LocalParser(
        scratch,
        transcribe: (bytes) async {
          calls++;
          expect(bytes, isNotEmpty);
          return ['SYNTHETIC', 'Haemoglobin 11.2 g/dL'];
        },
      );
      final lines = await parser.parse(report, sparsePdf());
      expect(calls, 1);
      expect(lines.last.text, 'Haemoglobin 11.2 g/dL');
      expect(lines.map((l) => l.method), everyElement('vision'));
    },
  );

  test(
    'Sparse PDF preserves readable native text as incomplete when vision fails',
    () async {
      final parser = LocalParser(
        scratch,
        transcribe: (_) async => throw StateError('No local model'),
      );
      final lines = await parser.parse(report, sparsePdf());
      expect(lines, isNotEmpty);
      expect(lines.map((l) => l.method), everyElement('text-sparse'));
      expect(
        lines.map((l) => l.text).join(),
        contains('SYNTHETIC scanned report header'),
      );
    },
  );
}
