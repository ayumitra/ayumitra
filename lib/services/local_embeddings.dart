import 'dart:io';

import 'package:flutter/services.dart';

class LocalEmbeddings {
  static const _channel = MethodChannel('app.ayumitra/embeddings');
  String? version;
  bool get available => version != null;
  Future<void> load(String path, String fingerprint) async {
    if (!path.endsWith('.litertlm') || !await File(path).exists()) {
      throw const FormatException(
        'Choose a local EmbeddingGemma 2 .litertlm file.',
      );
    }
    version = null;
    await _channel.invokeMethod('load', {'path': path});
    version = 'embeddinggemma2:$fingerprint';
  }

  Future<List<double>> embed(String text, {bool document = false}) async {
    if (!available) throw StateError('EmbeddingGemma 2 is not loaded.');
    final prefix = document
        ? 'task: search result | text: '
        : 'task: search query | text: ';
    final raw = await _channel.invokeListMethod<num>('embed', {
      'text': '$prefix${text.trim()}',
    });
    if (raw == null || raw.isEmpty || raw.any((x) => !x.isFinite)) {
      throw StateError('EmbeddingGemma 2 returned an invalid vector.');
    }
    return raw.map((x) => x.toDouble()).toList();
  }
}
