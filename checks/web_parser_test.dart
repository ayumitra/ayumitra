import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/services/web_parser.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

// Runs the same parser through native PDFium on a configured host or through
// its browser WASM engine with `flutter test --platform chrome ...`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? scratch;
  setUpAll(() async {
    if (kIsWeb) {
      Pdfrx.pdfiumWasmModulesUrl = 'assets/packages/pdfrx/assets/';
      Pdfrx.pdfiumWasmWithCredentials = false;
    } else {
      scratch = await Directory.systemTemp.createTemp(
        'ayumitra-web-parser-test-',
      );
      Pdfrx.cacheDirectoryPath = scratch!.path;
      var modulePath = Platform.environment['PDFIUM_PATH'];
      if (modulePath == null && Platform.isMacOS) {
        final config = File('.dart_tool/package_config.json');
        final packages =
            (jsonDecode(await config.readAsString()) as Map)['packages']
                as List;
        final pdfium = packages.cast<Map>().firstWhere(
          (package) => package['name'] == 'pdfium_flutter',
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
          'Set PDFIUM_PATH for these host checks, or run them on Chrome.',
        );
      }
      Pdfrx.pdfiumModulePath = modulePath;
    }
    await pdfrxFlutterInitialize();
  });
  tearDownAll(() async {
    if (scratch != null) await scratch!.delete(recursive: true);
  });

  test(
    'digital PDF keeps spatial table rows, page IDs, and the original buffer',
    () async {
      var calls = 0;
      final parser = WebParser(
        transcribe: (_) async {
          calls++;
          return [];
        },
      );
      final bytes = _pdf([_digitalPage, _digitalPage]);
      final original = Uint8List.fromList(bytes);
      final lines = await parser.parse(_report('pdf'), bytes);
      expect(calls, 0);
      expect(bytes, orderedEquals(original));
      expect(lines.map((line) => line.page).toSet(), {1, 2});
      expect(lines.map((line) => line.id).toSet().length, lines.length);
      expect(WebParser.requiresReview(lines), isFalse);
      for (final line in lines.where(
        (line) => line.text.contains('Hemoglobin'),
      )) {
        expect(line.text, contains('11.2'));
        expect(line.text, contains('g/dL'));
        expect(line.text, contains('10.0-14.0'));
        expect(line.bounds, hasLength(4));
        expect(line.bounds!.first, closeTo(50, 1));
        expect(line.bounds![1], greaterThan(0));
        expect(line.bounds![2], greaterThan(100));
        expect(line.pageWidth, 600);
        expect(line.pageHeight, 800);
      }
      expect(
        lines.where((line) => line.text.contains('Hemoglobin')),
        hasLength(2),
      );
    },
  );

  test(
    'scanned PDF sends a bounded PNG page to vision, never PDF bytes',
    () async {
      var calls = 0;
      final image = img.Image(width: 20, height: 30);
      img.fill(image, color: img.ColorRgb8(240, 240, 240));
      final jpg = Uint8List.fromList(img.encodeJpg(image));
      final parser = WebParser(
        transcribe: (bytes) async {
          calls++;
          expect(
            bytes.take(8),
            orderedEquals([137, 80, 78, 71, 13, 10, 26, 10]),
          );
          final rendered = img.decodePng(bytes)!;
          expect(
            rendered.width,
            lessThanOrEqualTo(WebParser.maxImageDimension),
          );
          expect(
            rendered.height,
            lessThanOrEqualTo(WebParser.maxImageDimension),
          );
          return ['SYNTHETIC scan', 'Hemoglobin 11.2 g/dL'];
        },
      );
      final lines = await parser.parse(
        _report('pdf'),
        _pdf(['q 560 0 0 760 20 20 cm /Im1 Do Q'], jpg: jpg),
      );
      expect(calls, 1);
      expect(lines.last.text, 'Hemoglobin 11.2 g/dL');
      expect(lines.map((line) => line.method), everyElement('vision'));
      expect(lines.every((line) => line.bounds == null), isTrue);
      expect(WebParser.requiresReview(lines), isTrue);
    },
  );

  test(
    'rotated PDF preserves logical table rows with display coordinates',
    () async {
      final lines = await WebParser().parse(
        _report('pdf'),
        _pdf([_digitalPage], rotation: 90),
      );
      final row = lines.firstWhere((line) => line.text.contains('Hemoglobin'));
      expect(row.text, contains('11.2'));
      expect(row.text, contains('g/dL'));
      expect(row.text, contains('10.0-14.0'));
      expect(row.pageWidth, 800);
      expect(row.pageHeight, 600);
      expect(row.bounds![0], greaterThanOrEqualTo(0));
      expect(row.bounds![1], greaterThanOrEqualTo(0));
      expect(row.bounds![0] + row.bounds![2], lessThanOrEqualTo(800));
      expect(row.bounds![1] + row.bounds![3], lessThanOrEqualTo(600));
      expect(WebParser.requiresReview(lines), isFalse);
    },
  );

  test(
    'sparse text survives failed vision and remains explicitly incomplete',
    () async {
      final parser = WebParser(
        transcribe: (_) async => throw StateError('Vision is unavailable'),
      );
      final lines = await parser.parse(
        _report('pdf'),
        _pdf(['BT /F1 12 Tf 50 750 Td (SYNTHETIC scan header) Tj ET']),
      );
      expect(
        lines.map((line) => line.text).join(),
        contains('SYNTHETIC scan header'),
      );
      expect(lines.map((line) => line.method), everyElement('text-sparse'));
      expect(WebParser.requiresReview(lines), isTrue);
    },
  );

  test(
    'unreadable pages do not erase readable pages or invent source text',
    () async {
      final lines = await WebParser().parse(
        _report('pdf'),
        _pdf([_digitalPage, '']),
      );
      expect(lines.where((line) => line.page == 1), isNotEmpty);
      final unreadable = lines.where((line) => line.page == 2).single;
      expect(unreadable.text, isEmpty);
      expect(unreadable.method, 'text-sparse');
      expect(unreadable.bounds, isNull);
      expect(WebParser.requiresReview(lines), isTrue);
    },
  );

  test(
    'limits reject excessive bytes and pages before calling transcription',
    () async {
      var calls = 0;
      final parser = WebParser(
        transcribe: (_) async {
          calls++;
          return [];
        },
      );
      await expectLater(
        parser.parse(_report('pdf'), Uint8List(WebParser.maxBytes + 1)),
        throwsFormatException,
      );
      await expectLater(
        parser.parse(_report('pdf'), _pdf(List.filled(31, ''))),
        throwsFormatException,
      );
      expect(calls, 0);
    },
  );

  test(
    'images are resized and encoded as PNG with unverified source rows',
    () async {
      final parser = WebParser(
        transcribe: (bytes) async {
          final image = img.decodePng(bytes)!;
          expect(image.width, 2400);
          expect(image.height, lessThanOrEqualTo(2));
          return ['SYNTHETIC image row'];
        },
      );
      final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 2501, height: 2)),
      );
      final lines = await parser.parse(_report('png'), bytes);
      expect(lines.single.method, 'vision');
      expect(lines.single.bounds, isNull);
      expect(WebParser.requiresReview(lines), isTrue);
    },
  );

  test(
    'text reading preserves source line numbers without using vision',
    () async {
      final lines = await WebParser().parse(
        _report('txt'),
        Uint8List.fromList(utf8.encode('SYNTHETIC\n\nHemoglobin 11.2 g/dL\n')),
      );
      expect(lines.map((line) => line.id), ['p1-l1', 'p1-l3']);
      expect(WebParser.requiresReview(lines), isFalse);
      expect(WebParser.requiresReview([]), isTrue);
      await expectLater(
        WebParser().parse(_report('zip'), Uint8List.fromList([1])),
        throwsFormatException,
      );
    },
  );
}

Report _report(String extension) => Report(
  id: 'synthetic',
  profileId: 'example',
  name: 'SYNTHETIC.$extension',
  extension: extension,
  digest: 'test',
  importedAt: DateTime(2026),
);

const _digitalPage = '''
BT /F1 12 Tf 50 750 Td (SYNTHETIC medical laboratory report - not a real patient) Tj ET
BT /F1 12 Tf 50 730 Td (Clinical report date: 2026-10-01. English local parser evaluation fixture.) Tj ET
BT /F1 12 Tf 50 710 Td (Results below retain exact source values, units, and printed reference ranges.) Tj ET
BT /F1 12 Tf 50 650 Td (Hemoglobin) Tj ET
BT /F1 12 Tf 220 650 Td (11.2) Tj ET
BT /F1 12 Tf 300 650 Td (g/dL) Tj ET
BT /F1 12 Tf 390 650 Td (10.0-14.0) Tj ET
''';

Uint8List _pdf(List<String> streams, {Uint8List? jpg, int rotation = 0}) {
  final pageCount = streams.length;
  final fontId = 3 + pageCount * 2;
  final imageId = fontId + 1;
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${List.generate(pageCount, (index) => '${3 + index * 2} 0 R').join(' ')}] /Count $pageCount >>',
  ];
  for (var i = 0; i < pageCount; i++) {
    final pageId = 3 + i * 2;
    objects.add(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Rotate $rotation /Resources << '
      '/Font << /F1 $fontId 0 R >> ${jpg == null ? '' : '/XObject << /Im1 $imageId 0 R >>'} >> /Contents ${pageId + 1} 0 R >>',
    );
    objects.add(
      '<< /Length ${streams[i].length} >>\nstream\n${streams[i]}\nendstream',
    );
  }
  objects.add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  if (jpg != null) {
    objects.add(
      '<< /Type /XObject /Subtype /Image /Width 20 /Height 30 '
      '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpg.length} >>\nstream\n${latin1.decode(jpg)}\nendstream',
    );
  }
  var pdf = '%PDF-1.4\n';
  final offsets = <int>[];
  for (final (index, object) in objects.indexed) {
    offsets.add(pdf.length);
    pdf += '${index + 1} 0 obj\n$object\nendobj\n';
  }
  final xref = pdf.length;
  pdf += 'xref\n0 ${objects.length + 1}\n0000000000 65535 f \n';
  for (final offset in offsets) {
    pdf += '${offset.toString().padLeft(10, '0')} 00000 n \n';
  }
  pdf +=
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n';
  return Uint8List.fromList(latin1.encode(pdf));
}
