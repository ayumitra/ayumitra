import 'dart:io';
import 'dart:typed_data';

import 'package:ayumitra/domain/camera_pages.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/services/local_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  group('camera report originals', () {
    test('preserves every original byte and capture order for 1–5 pages', () {
      for (var count = 1; count <= CameraPages.maxPages; count++) {
        final originals = List.generate(
          count,
          (page) => Uint8List.fromList([0, 255, page, 13, 10, 128]),
        );
        final restored = CameraPages.decode(CameraPages.encode(originals));
        expect(restored.length, count);
        for (var page = 0; page < count; page++) {
          expect(restored[page], originals[page]);
        }
      }
    });

    test('returned pages do not share writable original or sibling bytes', () {
      final original = Uint8List.fromList([1, 2, 3]);
      final bundle = CameraPages.encode([original, original]);
      original[0] = 99;
      final restored = CameraPages.decode(bundle);
      restored.first[0] = 100;
      expect(restored.last, [1, 2, 3]);
      expect(CameraPages.decode(bundle).first, [1, 2, 3]);
    });

    test('refuses absent, empty and more than five image originals', () {
      expect(() => CameraPages.encode([]), throwsFormatException);
      expect(() => CameraPages.encode([Uint8List(0)]), throwsFormatException);
      expect(
        () => CameraPages.encode(List.generate(6, (_) => Uint8List(1))),
        throwsFormatException,
      );
    });

    test('includes container overhead in the combined 30 MB limit', () {
      final limit = Uint8List(CameraPages.maxBytes - 14);
      final bundle = CameraPages.encode([limit]);
      expect(bundle.length, CameraPages.maxBytes);
      expect(CameraPages.decode(bundle).single.length, limit.length);
      expect(
        () => CameraPages.encode([limit, Uint8List(1)]),
        throwsFormatException,
      );
      expect(
        () => CameraPages.encode([Uint8List(CameraPages.maxBytes)]),
        throwsFormatException,
      );
    });

    test('rejects unknown magic/version, invalid page counts and headers', () {
      final good = CameraPages.encode([
        Uint8List.fromList([1, 2]),
      ]);
      for (final mutation in <(int, int)>[
        (0, 0),
        (7, 0),
        (8, 0),
        (8, 2),
        (9, 0),
        (9, 6),
        (9, 255),
      ]) {
        final corrupt = Uint8List.fromList(good);
        corrupt[mutation.$1] = mutation.$2;
        expect(() => CameraPages.decode(corrupt), throwsFormatException);
      }
      expect(() => CameraPages.decode(Uint8List(0)), throwsFormatException);
      final truncatedHeader = Uint8List.fromList(good)..[9] = 5;
      expect(() => CameraPages.decode(truncatedHeader), throwsFormatException);
    });

    test(
      'rejects zero, oversized or truncated length entries and trailing data',
      () {
        final good = CameraPages.encode([
          Uint8List.fromList([1, 2, 3]),
        ]);
        for (final length in [0, 4, CameraPages.maxBytes, 0xffffffff]) {
          final corrupt = Uint8List.fromList(good);
          ByteData.sublistView(corrupt).setUint32(10, length, Endian.big);
          expect(() => CameraPages.decode(corrupt), throwsFormatException);
        }
        expect(
          () => CameraPages.decode(Uint8List.fromList(good.sublist(0, 15))),
          throwsFormatException,
        );
        expect(
          () => CameraPages.decode(Uint8List.fromList([...good, 0])),
          throwsFormatException,
        );
        expect(
          () => CameraPages.decode(Uint8List(CameraPages.maxBytes + 1)),
          throwsFormatException,
        );
      },
    );
  });

  group('camera report source pages', () {
    final report = Report(
      id: 'synthetic-camera-report',
      profileId: 'synthetic-profile',
      name: 'Synthetic camera report.ayupages',
      extension: 'images',
      digest: 'synthetic-only',
      importedAt: DateTime(2026, 10, 13),
    );
    Uint8List image() =>
        Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));

    test(
      'transcribes sequentially with independent page source identifiers',
      () async {
        var calls = 0;
        var active = 0;
        final parser = LocalParser(
          Directory.systemTemp,
          transcribe: (_) async {
            expect(
              active,
              0,
              reason: 'edge inference processes one image at a time',
            );
            active++;
            final page = ++calls;
            await Future<void>.delayed(Duration.zero);
            active--;
            return ['Synthetic page $page', 'Synthetic second row'];
          },
        );
        final lines = await parser.parse(
          report,
          CameraPages.encode([image(), image()]),
        );
        expect(calls, 2);
        expect(lines.map((l) => l.id), ['p1-l1', 'p1-l2', 'p2-l1', 'p2-l2']);
        expect(lines.map((l) => l.page), [1, 1, 2, 2]);
        expect(lines.first.text, 'Synthetic page 1');
        expect(lines[2].text, 'Synthetic page 2');
        expect(
          lines.every((l) => l.method == 'vision' && l.bounds == null),
          isTrue,
        );
      },
    );

    test(
      'an unreadable page rejects the whole job and stops later inference',
      () async {
        var calls = 0;
        final parser = LocalParser(
          Directory.systemTemp,
          transcribe: (_) async {
            if (++calls == 2) {
              throw const FormatException('Synthetic page failure.');
            }
            return ['Synthetic readable page'];
          },
        );
        await expectLater(
          parser.parse(report, CameraPages.encode([image(), image(), image()])),
          throwsFormatException,
        );
        expect(calls, 2);
      },
    );

    test('an empty page cannot be hidden by earlier readable pages', () async {
      var calls = 0;
      final parser = LocalParser(
        Directory.systemTemp,
        transcribe: (_) async =>
            ++calls == 1 ? ['Synthetic readable page'] : [],
      );
      await expectLater(
        parser.parse(report, CameraPages.encode([image(), image()])),
        throwsFormatException,
      );
      expect(calls, 2);
    });

    test('invalid containers are rejected before vision is invoked', () async {
      var calls = 0;
      final parser = LocalParser(
        Directory.systemTemp,
        transcribe: (_) async {
          calls++;
          return ['Synthetic'];
        },
      );
      await expectLater(
        parser.parse(report, Uint8List(0)),
        throwsFormatException,
      );
      expect(calls, 0);
    });
  });
}
