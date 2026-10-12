import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

import '../app_controller.dart';
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
  int page = 1, pageCount = 1;
  @override
  void initState() {
    super.initState();
    page = widget.line?.page ?? 1;
    original = widget.controller.original(widget.report);
    if (widget.report.extension == 'pdf') rendered = _render(page);
  }

  Future<Uint8List> _render(int number) async {
    final document = await PdfDocument.openData(await original);
    try {
      pageCount = document.pages.length;
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Original report')),
    body: FutureBuilder<Uint8List>(
      future: rendered ?? original,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(
            child: Text('The original could not be opened locally.'),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return Column(
          children: [
            if (widget.report.extension == 'pdf')
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Previous page',
                    onPressed: page > 1
                        ? () => setState(() => rendered = _render(--page))
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('Page $page of $pageCount'),
                  IconButton(
                    tooltip: 'Next page',
                    onPressed: page < pageCount
                        ? () => setState(() => rendered = _render(++page))
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
                                    if (line != null &&
                                        line.page == page &&
                                        line.bounds != null &&
                                        line.pageWidth != null &&
                                        line.pageHeight != null)
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
            if (widget.line != null)
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
}
