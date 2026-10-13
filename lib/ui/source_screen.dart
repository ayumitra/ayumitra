import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

import '../app_controller.dart';
import '../domain/camera_pages.dart';
import '../domain/records.dart';

class SourceScreen extends StatefulWidget {
  const SourceScreen({
    super.key,
    required this.controller,
    required this.report,
    this.line,
  });
  final AppController controller;
  final Report report;
  final SourceLine? line;
  @override
  State<SourceScreen> createState() => _SourceScreenState();
}

class _SourceScreenState extends State<SourceScreen> {
  late Future<Uint8List> original;
  Future<Uint8List>? rendered;
  Future<List<Uint8List>>? cameraPages;
  int page = 1, pageCount = 1;
  @override
  void initState() {
    super.initState();
    page = widget.line?.page ?? 1;
    original = widget.controller.original(widget.report);
    // A guarded route may never mount FutureBuilder. Observe errors without
    // replacing the future, so denied reads remain safely handled either way.
    original.ignore();
    if (widget.report.extension == 'images') {
      cameraPages = original.then(CameraPages.decode);
      cameraPages!.ignore();
    }
    if (_hasPages) {
      rendered = _render(page);
      rendered!.ignore();
    }
  }

  bool get _hasPages =>
      widget.report.extension == 'pdf' || widget.report.extension == 'images';

  bool _canHighlight(SourceLine line) {
    final bounds = line.bounds;
    final width = line.pageWidth;
    final height = line.pageHeight;
    return line.page == page &&
        bounds != null &&
        bounds.length == 4 &&
        bounds.every((value) => value.isFinite && value >= 0) &&
        bounds[2] > 0 &&
        bounds[3] > 0 &&
        width != null &&
        width.isFinite &&
        width > 0 &&
        height != null &&
        height.isFinite &&
        height > 0;
  }

  void _showPage(int number) {
    if (number < 1 || number > pageCount) return;
    setState(() {
      page = number;
      rendered = _render(number);
      rendered!.ignore();
    });
  }

  Future<Uint8List> _render(int number) async {
    if (widget.report.extension == 'images') {
      final pages = await cameraPages!;
      pageCount = pages.length;
      if (number < 1 || number > pageCount) {
        throw StateError('Page unavailable.');
      }
      return pages[number - 1];
    }
    final document = await PdfDocument.openData(await original);
    try {
      pageCount = document.pages.length;
      if (number < 1 || number > pageCount) {
        throw StateError('Page unavailable.');
      }
      final source = document.pages[number - 1];
      final image = await source.render(
        fullWidth: source.width * 2,
        fullHeight: source.height * 2,
      );
      if (image == null) throw StateError('Page unavailable.');
      try {
        return Uint8List.fromList(
          img.encodePng(
            img.Image.fromBytes(
              width: image.width,
              height: image.height,
              bytes: image.pixels.buffer,
              order: img.ChannelOrder.bgra,
            ),
          ),
        );
      } finally {
        image.dispose();
      }
    } finally {
      await document.dispose();
    }
  }

  Widget _originalText(String text) {
    final quote = widget.line?.text;
    final start = quote == null || quote.isEmpty ? -1 : text.indexOf(quote);
    return SelectionArea(
      child: start < 0
          ? Text(text)
          : Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: text.substring(0, start)),
                  TextSpan(
                    text: quote,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      backgroundColor: Color(0xffdceadd),
                    ),
                  ),
                  TextSpan(text: text.substring(start + quote!.length)),
                ],
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      // Stale-screen guard: the original bytes are fetched once in initState
      // and cached, so without this check the previous profile's content
      // would stay rendered after a profile switch. Re-verify ownership on
      // every controller notification and hide everything (text, image, page
      // quotes) unless the report still belongs to the active profile. The
      // guard itself carries no names or quoted content. The initState fetch
      // and its read-time vault checks are unchanged, and nothing is
      // re-fetched or copied here.
      final owned =
          c.activeProfileId == widget.report.profileId &&
          c.reports.any((r) => r.id == widget.report.id);
      if (!owned) {
        return Scaffold(
          appBar: AppBar(title: const Text('Original report')),
          body: const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'This original is not available in the active profile. '
                'Switch back to its profile to view it again.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(title: const Text('Original report')),
        body: FutureBuilder<Uint8List>(
          future: rendered ?? original,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Center(
                child: Text('The original could not be opened locally.'),
              );
            }
            if (!snapshot.hasData ||
                snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            return Column(
              children: [
                if (_hasPages)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Previous page',
                        onPressed: page > 1 ? () => _showPage(page - 1) : null,
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text('Page $page of $pageCount'),
                      IconButton(
                        tooltip: 'Next page',
                        onPressed: page < pageCount
                            ? () => _showPage(page + 1)
                            : null,
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                Expanded(
                  child: widget.report.extension == 'txt'
                      ? SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: _originalText(utf8.decode(snapshot.data!)),
                        )
                      : InteractiveViewer(
                          minScale: .5,
                          maxScale: 5,
                          child: Center(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final image = img.decodeImage(snapshot.data!);
                                if (image == null) {
                                  return const Text('Image unavailable.');
                                }
                                final line = widget.line;
                                return AspectRatio(
                                  aspectRatio: image.width / image.height,
                                  child: LayoutBuilder(
                                    builder: (context, size) => Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Image.memory(
                                          snapshot.data!,
                                          fit: BoxFit.fill,
                                        ),
                                        if (line != null && _canHighlight(line))
                                          Positioned(
                                            left:
                                                line.bounds![0] /
                                                line.pageWidth! *
                                                size.maxWidth,
                                            top:
                                                line.bounds![1] /
                                                line.pageHeight! *
                                                size.maxHeight,
                                            width:
                                                line.bounds![2] /
                                                line.pageWidth! *
                                                size.maxWidth,
                                            height:
                                                line.bounds![3] /
                                                line.pageHeight! *
                                                size.maxHeight,
                                            child: Container(
                                              decoration: BoxDecoration(
                                                color: Colors.amber.withValues(
                                                  alpha: .22,
                                                ),
                                                border: Border.all(
                                                  color: Colors.orange,
                                                  width: 2,
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                ),
                if (widget.line != null && widget.line!.page == page)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: SelectionArea(
                      child: Text(
                        widget.line!.text,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      );
    },
  );
}
