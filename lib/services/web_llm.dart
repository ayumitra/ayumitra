import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'local_embeddings.dart';
import 'local_intelligence.dart';

/// Local-AI bridge for the in-memory web client.
///
/// Everything stays on the user's machine: requests go only to a
/// user-configured **localhost** endpoint (Ollama-compatible by default).
/// Any non-loopback endpoint is refused. No API keys, no cloud calls.
bool _isLoopback(Uri uri) {
  if (uri.scheme != 'http') return false;
  final host = uri.host.toLowerCase();
  return host == 'localhost' || host == '127.0.0.1' || host == '::1';
}

class WebIntelligence extends LocalIntelligence {
  WebIntelligence({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  /// Base URL of the local model server. Loopback only.
  String endpoint = 'http://127.0.0.1:11434';

  /// Local chat model name, e.g. `gemma3:1b`. Empty means not configured.
  String chatModel = '';

  /// Optional local vision model name for scan transcription.
  String visionModel = '';

  bool get visionAvailable => visionModel.trim().isNotEmpty;

  @override
  bool get available => chatModel.trim().isNotEmpty;

  Uri _url(String path) {
    final uri = Uri.parse('$endpoint$path');
    if (!_isLoopback(uri)) {
      throw StateError('Only a localhost model server is allowed.');
    }
    return uri;
  }

  @override
  Future<void> configure(String localPath, String family) {
    throw StateError(
      'Model files are installed in the mobile app. This client uses your localhost model server instead.',
    );
  }

  @override
  Future<String> generate(String instruction, String input) async {
    if (!available) {
      throw StateError('Set a local chat model in settings first.');
    }
    final response = await _client
        .post(
          _url('/api/generate'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': chatModel.trim(),
            'system': instruction,
            'prompt': input,
            'stream': false,
            'temperature': 0,
          }),
        )
        .timeout(const Duration(minutes: 5));
    if (response.statusCode != 200) {
      throw StateError(
        'The local model server returned ${response.statusCode}. '
        'Is it running at $endpoint?',
      );
    }
    final data = jsonDecode(response.body) as Map;
    final text = (data['response'] as String? ?? '').trim();
    if (text.isEmpty) throw const FormatException('Empty local response.');
    return text;
  }

  @override
  Future<List<String>> transcribeImage(Uint8List bytes) =>
      transcribeBytes(bytes);

  /// Transcribes a scan/photo with the configured local vision model.
  Future<List<String>> transcribeBytes(List<int> bytes) async {
    if (!visionAvailable) {
      throw StateError('Set a local vision model in settings first.');
    }
    final response = await _client
        .post(
          _url('/api/generate'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': visionModel.trim(),
            'system': transcriptionPrompt,
            'prompt':
                'Transcribe the visible English text, '
                'preserving table rows.',
            'images': [base64Encode(bytes)],
            'stream': false,
            'temperature': 0,
          }),
        )
        .timeout(const Duration(minutes: 5));
    if (response.statusCode != 200) {
      throw StateError(
        'The local vision model returned ${response.statusCode}.',
      );
    }
    final data = jsonDecode(response.body) as Map;
    final output = ((data['response'] as String?) ?? '')
        .trim()
        .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
        .replaceFirst(RegExp(r'\s*```$'), '');
    final decoded = jsonDecode(output);
    if (decoded is! Map || decoded['lines'] is! List) {
      throw const FormatException('Invalid local transcript.');
    }
    final lines = decoded['lines'] as List;
    if (lines.length > 300 ||
        lines.any((l) => l is! String || l.length > 2000)) {
      throw const FormatException('Invalid local transcript.');
    }
    return lines
        .cast<String>()
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }
}

/// Local embeddings for the in-memory web client via the localhost server
/// (`/api/embed`). Same loopback-only rule as [WebIntelligence].
class WebEmbeddings extends LocalEmbeddings {
  WebEmbeddings({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  String endpoint = 'http://127.0.0.1:11434';

  /// Local embedding model name, e.g. `embeddinggemma`. Empty = not set.
  String embeddingModel = '';

  @override
  bool get available => embeddingModel.trim().isNotEmpty;

  @override
  Future<void> load(String path, String fingerprint) {
    throw StateError(
      'Model files are installed in the mobile app. This client uses your localhost model server instead.',
    );
  }

  @override
  Future<List<double>> embed(String text, {bool document = false}) async {
    if (!available) throw StateError('Set a local embedding model first.');
    final uri = Uri.parse('$endpoint/api/embed');
    if (!_isLoopback(uri)) {
      throw StateError('Only a localhost model server is allowed.');
    }
    final response = await _client
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': embeddingModel.trim(),
            'input': text.trim(),
          }),
        )
        .timeout(const Duration(minutes: 2));
    if (response.statusCode != 200) {
      throw StateError('Local embeddings returned ${response.statusCode}.');
    }
    final data = jsonDecode(response.body) as Map;
    final vectors = (data['embeddings'] as List?)?.firstOrNull;
    if (vectors is! List || vectors.isEmpty) {
      throw StateError('Local embeddings returned an invalid vector.');
    }
    final result = vectors.map((x) => (x as num).toDouble()).toList();
    if (result.any((x) => !x.isFinite)) {
      throw StateError('Local embeddings returned an invalid vector.');
    }
    version ??= 'ollama:${embeddingModel.trim()}';
    return result;
  }
}
