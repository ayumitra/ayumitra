import 'task_cancellation.dart';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

import '../domain/records.dart';

/// In-memory report reading for the browser client. PDF bytes are opened only
/// by the local PDF engine; transcription receives PNG image bytes, never PDF.
class WebParser {
  WebParser({this.transcribe});

  final Future<List<String>> Function(Uint8List imageBytes)? transcribe;
  static const maxBytes = 30 * 1024 * 1024;
  static const maxPages = 30;
  static const maxImageDimension = 2400;
  static const _maxDecodedImagePixels = 32 * 1000 * 1000;
  static const _maxSourceRows = 12000;

  /// Incomplete text layers and model transcriptions require original review.
  /// Empty sparse rows mark an unreadable page without inventing source text.
  static bool requiresReview(List<SourceLine> lines) =>
      lines.isEmpty ||
      lines.any(
        (line) => line.method == 'vision' || line.method == 'text-sparse',
      );

  Future<List<SourceLine>> parse(Report report, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('Choose a non-empty report up to 30 MB.');
    }
    final extension = report.extension.toLowerCase();
    if (extension == 'txt') {
      final rows = utf8.decode(bytes).split(RegExp(r'\r?\n'));
      if (rows.length > _maxSourceRows) {
        throw const FormatException('This text report contains too many rows.');
      }
      return rows.indexed
          .where((row) => row.$2.trim().isNotEmpty)
          .map(
            (row) => SourceLine(
              id: 'p1-l${row.$1 + 1}',
              page: 1,
              text: row.$2.trim(),
            ),
          )
          .toList();
    }
    if (extension != 'pdf') {
      if (!{'png', 'jpg', 'jpeg'}.contains(extension)) {
        throw const FormatException('Choose a PDF, PNG, JPG, or text report.');
      }
      return _vision(bytes, 1);
    }

    // Keep the caller's original buffer intact: the web worker must copy it.
    final document = await PdfDocument.openData(
      bytes,
      allowDataOwnershipTransfer: false,
    );
    try {
      if (document.pages.isEmpty || document.pages.length > maxPages) {
        throw const FormatException('Choose a PDF with 1 to 30 pages.');
      }
      final result = <SourceLine>[];
      for (final page in document.pages) {
        if (!page.width.isFinite ||
            !page.height.isFinite ||
            page.width <= 0 ||
            page.height <= 0) {
          throw const FormatException('A PDF page has invalid dimensions.');
        }
        var characters = 0;
        var nativeRows = <SourceLine>[];
        try {
          final text = await page.loadStructuredText();
          characters = RegExp(r'[a-zA-Z0-9]').allMatches(text.fullText).length;
          nativeRows = _nativeRows(page, text, sparse: characters < 150);
        } on TaskCancelled {
          rethrow;
        } catch (_) {
          // A failed text layer may still be a readable scan after rendering.
        }
        if (characters >= 150 && nativeRows.isNotEmpty) {
          result.addAll(nativeRows);
        } else {
          var visionRows = <SourceLine>[];
          if (transcribe != null) {
            try {
              visionRows = await _transcribePage(page);
            } on TaskCancelled {
              rethrow;
            } catch (_) {
              // Keep readable native rows and explicitly mark incomplete pages.
              // Never substitute model guesses or silently mark a scan ready.
            }
          }
          if (visionRows.isNotEmpty) {
            result.addAll(visionRows);
          } else if (nativeRows.isNotEmpty) {
            result.addAll(nativeRows);
          } else {
            result.add(
              SourceLine(
                id: 'p${page.pageNumber}-incomplete',
                page: page.pageNumber,
                text: '',
                method: 'text-sparse',
                pageWidth: page.width,
                pageHeight: page.height,
              ),
            );
          }
        }
        if (result.length > _maxSourceRows) {
          throw const FormatException(
            'This PDF contains too many source rows.',
          );
        }
      }
      return result;
    } finally {
      await document.dispose();
    }
  }

  List<SourceLine> _nativeRows(
    PdfPage page,
    PdfPageText text, {
    required bool sparse,
  }) {
    final fragments =
        text.fragments
            .where((fragment) => fragment.text.trim().isNotEmpty)
            .map((fragment) => (fragment.text.trim(), fragment.bounds))
            .where(
              (fragment) =>
                  fragment.$2.left.isFinite &&
                  fragment.$2.top.isFinite &&
                  fragment.$2.width.isFinite &&
                  fragment.$2.height.isFinite,
            )
            .toList()
          ..sort((a, b) {
            final y = b.$2.top.compareTo(a.$2.top);
            return y == 0 ? a.$2.left.compareTo(b.$2.left) : y;
          });
    // Group in logical PDF coordinates before applying page /Rotate metadata;
    // rotated display columns must not separate labels from their values.
    final rows = <List<(String, PdfRect)>>[];
    for (final fragment in fragments) {
      if (rows.isEmpty ||
          (rows.last.first.$2.top - fragment.$2.top).abs() > 4) {
        rows.add([]);
      }
      rows.last.add(fragment);
    }
    return rows.indexed.map((entry) {
      final row = entry.$2..sort((a, b) => a.$2.left.compareTo(b.$2.left));
      final logicalBounds = row
          .map((fragment) => fragment.$2)
          .reduce((a, b) => a.merge(b));
      final bounds = logicalBounds.toRect(page: page);
      return SourceLine(
        id: 'p${page.pageNumber}-l${entry.$1 + 1}',
        page: page.pageNumber,
        text: row.map((fragment) => fragment.$1).join(' '),
        method: sparse ? 'text-sparse' : 'text',
        bounds: [bounds.left, bounds.top, bounds.width, bounds.height],
        pageWidth: page.width,
        pageHeight: page.height,
      );
    }).toList();
  }

  Future<List<SourceLine>> _transcribePage(PdfPage page) async {
    final scale = min(3.0, maxImageDimension / max(page.width, page.height));
    final rendered = await page.render(
      fullWidth: page.width * scale,
      fullHeight: page.height * scale,
      backgroundColor: 0xffffffff,
    );
    if (rendered == null) {
      throw const FormatException('A PDF page could not be rendered.');
    }
    try {
      final image = img.Image.fromBytes(
        width: rendered.width,
        height: rendered.height,
        bytes: rendered.pixels.buffer,
        bytesOffset: rendered.pixels.offsetInBytes,
        rowStride: rendered.width * 4,
        order: img.ChannelOrder.bgra,
      );
      return await _vision(
        Uint8List.fromList(img.encodePng(image)),
        page.pageNumber,
      );
    } finally {
      rendered.dispose();
    }
  }

  Future<List<SourceLine>> _vision(Uint8List bytes, int page) async {
    if (transcribe == null) {
      throw StateError('A local vision model is needed to read this image.');
    }
    final decoder = img.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width * info.height > _maxDecodedImagePixels) {
      throw const FormatException(
        'Choose a readable image below 32 megapixels.',
      );
    }
    // Decode one frame only; an animated image cannot allocate arbitrary frames.
    final image = decoder!.decodeFrame(0);
    if (image == null) {
      throw const FormatException('The image could not be decoded.');
    }
    final scaled = max(image.width, image.height) > maxImageDimension
        ? img.copyResize(
            image,
            width: image.width >= image.height ? maxImageDimension : null,
            height: image.height > image.width ? maxImageDimension : null,
          )
        : image;
    final transcript = await transcribe!(
      Uint8List.fromList(img.encodePng(scaled)),
    );
    if (transcript.length > 300 ||
        transcript.any((line) => line.length > 2000)) {
      throw const FormatException('The local transcript is too large.');
    }
    return transcript.indexed
        .where((line) => line.$2.trim().isNotEmpty)
        .map(
          (line) => SourceLine(
            id: 'p$page-l${line.$1 + 1}',
            page: page,
            text: line.$2.trim(),
            method: 'vision',
            pageWidth: image.width.toDouble(),
            pageHeight: image.height.toDouble(),
          ),
        )
        .toList();
  }
}
