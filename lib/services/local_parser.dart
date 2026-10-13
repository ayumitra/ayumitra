import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

import '../domain/camera_pages.dart';
import '../domain/records.dart';

class LocalParser {
  LocalParser(this.scratch, {required this.transcribe});
  final Future<List<String>> Function(Uint8List) transcribe;
  final Directory scratch;

  Future<void> cleanScratch() async {
    if (await scratch.exists()) await scratch.delete(recursive: true);
    await scratch.create(recursive: true);
  }

  Future<List<SourceLine>> parse(Report report, Uint8List bytes) async {
    if (report.extension == 'images') {
      final pages = CameraPages.decode(bytes);
      final result = <SourceLine>[];
      for (final (index, page) in pages.indexed) {
        // Run one image at a time to fit edge memory. Every source identifier
        // includes its original page; an unsuccessful page fails the complete
        // job so a partial transcript never masquerades as a complete report.
        final lines = await _vision(page, index + 1);
        if (lines.isEmpty) {
          throw const FormatException(
            'A camera report page could not be read.',
          );
        }
        result.addAll(lines);
      }
      return result;
    }
    if (report.extension == 'txt') {
      return utf8
          .decode(bytes)
          .split(RegExp(r'\r?\n'))
          .indexed
          .where((x) => x.$2.trim().isNotEmpty)
          .map(
            (x) =>
                SourceLine(id: 'p1-l${x.$1 + 1}', page: 1, text: x.$2.trim()),
          )
          .toList();
    }
    if (report.extension != 'pdf') return _vision(bytes, 1);
    final document = await PdfDocument.openData(bytes);
    try {
      if (document.pages.length > 30) {
        throw const FormatException(
          'This version supports reports up to 30 pages. The original is saved.',
        );
      }
      final result = <SourceLine>[];
      for (final page in document.pages) {
        final text = await page.loadStructuredText();
        final characters = RegExp(
          r'[a-zA-Z0-9]',
        ).allMatches(text.fullText).length;
        if (characters >= 12) {
          final sparse = characters < 150;
          // Reconstruct spatial rows, so a table value stays beside its label.
          final fragments = [...text.fragments]
            ..sort((a, b) {
              final y = b.bounds.top.compareTo(a.bounds.top);
              return y == 0 ? a.bounds.left.compareTo(b.bounds.left) : y;
            });
          final rows = <List<PdfPageTextFragment>>[];
          for (final f in fragments.where((x) => x.text.trim().isNotEmpty)) {
            if (rows.isEmpty ||
                (rows.last.first.bounds.top - f.bounds.top).abs() > 4) {
              rows.add([]);
            }
            rows.last.add(f);
          }
          for (final (index, row) in rows.indexed) {
            row.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
            final bounds = row
                .map((x) => x.bounds)
                .reduce((a, b) => a.merge(b));
            result.add(
              SourceLine(
                id: 'p${page.pageNumber}-l${index + 1}',
                page: page.pageNumber,
                text: row.map((x) => x.text.trim()).join(' '),
                method: sparse ? 'text-sparse' : 'text',
                bounds: [
                  bounds.left,
                  page.height - bounds.top,
                  bounds.width,
                  bounds.height,
                ],
                pageWidth: page.width,
                pageHeight: page.height,
              ),
            );
          }
          if (!sparse) continue;
        }
        // A scan may have only a native watermark/header. Attempt transcription
        // for sparse text layers; retain readable native rows if vision is absent.
        try {
          final scale = min(3.0, 2400 / max(page.width, page.height));
          final rendered = await page.render(
            fullWidth: page.width * scale,
            fullHeight: page.height * scale,
          );
          if (rendered == null) {
            throw const FormatException('A page could not be rendered.');
          }
          try {
            final image = img.Image.fromBytes(
              width: rendered.width,
              height: rendered.height,
              bytes: rendered.pixels.buffer,
              order: img.ChannelOrder.bgra,
            );
            final vision = await _vision(
              Uint8List.fromList(img.encodePng(image)),
              page.pageNumber,
            );
            if (vision.isNotEmpty) {
              result.removeWhere((line) => line.page == page.pageNumber);
              result.addAll(vision);
            }
          } finally {
            rendered.dispose();
          }
        } catch (_) {
          if (characters < 12) rethrow;
          // Sparse native text is explicitly incomplete, never a ready report.
        }
      }
      return result;
    } finally {
      await document.dispose();
    }
  }

  Future<List<SourceLine>> _vision(Uint8List bytes, int page) async {
    final image = img.decodeImage(bytes);
    if (image == null) {
      throw const FormatException('The image could not be read.');
    }
    // Decode and resize in memory: no plaintext image copy is written to disk.
    final scaled = max(image.width, image.height) > 2400
        ? img.copyResize(
            image,
            width: image.width >= image.height ? 2400 : null,
            height: image.height > image.width ? 2400 : null,
          )
        : image;
    final lines = await transcribe(Uint8List.fromList(img.encodePng(scaled)));
    // Model transcripts are unverified. Never invent spatial coordinates.
    // Blank transcript rows are dropped so an empty page cannot masquerade
    // as a successful transcription.
    return lines.indexed
        .where((entry) => entry.$2.trim().isNotEmpty)
        .map(
          (entry) => SourceLine(
            id: 'p$page-l${entry.$1 + 1}',
            page: page,
            text: entry.$2,
            method: 'vision',
            pageWidth: image.width.toDouble(),
            pageHeight: image.height.toDouble(),
          ),
        )
        .toList();
  }
}
