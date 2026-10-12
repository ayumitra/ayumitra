import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'local_embeddings.dart';
import 'local_intelligence.dart';
import 'local_research.dart';

/// Strict-local bridge for the in-memory web client.
///
/// Localhost alone does not prove local inference: a localhost server can
/// front remote/cloud models. So nothing carrying report content is sent
/// until [WebIntelligence.connect] / [WebEmbeddings.connect] has verified
/// the exact configured models against live server metadata
/// (`GET /api/tags` + `POST /api/show`): installed locally (name + digest),
/// no `remote_host`/`remote_model` markers, and matching capabilities.
/// Verification never pulls or downloads models. Verification is refreshed
/// before every health-bearing call (not just at connect), and any failed
/// check, inference, or changed metadata clears the stored verification
/// instead of retaining a stale success.
///
/// Structured roles (organizer, extractor, planner, research, transcription)
/// request Ollama `format: 'json'` using the existing prompt constants;
/// summaries and free conversation stay natural language.
/// Every request enforces, in order: exact loopback-`http` endpoint (no
/// credentials/query/fragment/path, no `https`), `followRedirects: false`
/// with explicit 3xx rejection (metadata calls included), timeouts, and
/// response-size caps. No API keys, no cloud calls, no model downloads.
class LocalModelInfo {
  const LocalModelInfo({
    required this.name,
    required this.digest,
    this.capabilities = const [],
  });
  final String name, digest;
  final List<String> capabilities;
}

bool _isLoopbackHost(String host) {
  final lower = host.toLowerCase();
  return lower == 'localhost' || lower == '127.0.0.1' || lower == '::1';
}

/// Exact loopback-`http` endpoint, normalized via the Uri constructor so
/// IPv6 keeps its brackets (`http://[::1]:11434`). Anything else (https,
/// non-loopback, credentials, query, fragment, or a real path) is refused
/// before any request is built.
String _validatedBase(String raw) {
  final parsed = Uri.tryParse(raw.trim());
  if (parsed == null ||
      parsed.scheme != 'http' ||
      !_isLoopbackHost(parsed.host) ||
      parsed.userInfo.isNotEmpty ||
      parsed.query.isNotEmpty ||
      parsed.fragment.isNotEmpty ||
      (parsed.path.isNotEmpty && parsed.path != '/')) {
    throw const FormatException(
      'The model server must be a plain http://localhost URL with no credentials, query, or path.',
    );
  }
  final normalized = parsed.hasPort
      ? Uri(scheme: 'http', host: parsed.host, port: parsed.port)
      : Uri(scheme: 'http', host: parsed.host);
  return normalized.toString();
}

Future<Map> _readJson(
  http.Client client,
  http.Request request, {
  required Duration timeout,
  required int maxBytes,
  required String what,
}) async {
  request.followRedirects = false;
  final stopwatch = Stopwatch()..start();
  final streamed = await client.send(request).timeout(timeout);
  if (streamed.statusCode >= 300 && streamed.statusCode < 400) {
    throw StateError(
      '$what refused: the local server redirected the request. Nothing was followed off-device.',
    );
  }
  if (streamed.statusCode != 200) {
    throw StateError('$what failed (HTTP ${streamed.statusCode}).');
  }
  // Explicit gap timer + listener instead of Stream.timeout + await-for:
  // identical deadlines (30 s per chunk, overall call deadline, size cap),
  // but robust in every event-loop environment.
  final completer = Completer<List<int>>();
  final bytes = <int>[];
  late StreamSubscription<List<int>> sub;
  Timer? gap;
  Timer? deadline;
  void fail(Object error) {
    gap?.cancel();
    deadline?.cancel();
    unawaited(sub.cancel());
    if (!completer.isCompleted) completer.completeError(error);
  }

  void arm() {
    gap?.cancel();
    gap = Timer(const Duration(seconds: 30), () {
      fail(StateError('$what timed out while reading the local response.'));
    });
  }

  arm();
  final remaining = timeout - stopwatch.elapsed;
  deadline = Timer(remaining.isNegative ? Duration.zero : remaining, () {
    fail(StateError('$what exceeded its deadline.'));
  });
  sub = streamed.stream.listen(
    (chunk) {
      if (stopwatch.elapsed > timeout) {
        fail(StateError('$what exceeded its deadline.'));
        return;
      }
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) {
        fail(
          const FormatException(
            'The local response exceeded the safety limit.',
          ),
        );
        return;
      }
      arm();
    },
    onError: fail,
    onDone: () {
      gap?.cancel();
      deadline?.cancel();
      if (!completer.isCompleted) completer.complete(bytes);
    },
    cancelOnError: true,
  );
  final decoded = jsonDecode(utf8.decode(await completer.future));
  if (decoded is! Map) {
    throw const FormatException('Invalid local response.');
  }
  return decoded;
}

Future<Map> _postJson(
  http.Client client,
  Uri uri,
  Map<String, dynamic> body, {
  required Duration timeout,
  required int maxBytes,
  required String what,
}) {
  final request = http.Request('POST', uri)
    ..headers['Content-Type'] = 'application/json'
    ..body = jsonEncode(body);
  return _readJson(
    client,
    request,
    timeout: timeout,
    maxBytes: maxBytes,
    what: what,
  );
}

Future<Map> _getJson(
  http.Client client,
  Uri uri, {
  required Duration timeout,
  required int maxBytes,
  required String what,
}) => _readJson(
  client,
  http.Request('GET', uri),
  timeout: timeout,
  maxBytes: maxBytes,
  what: what,
);

/// Models installed on the localhost server (names + digests), for UI
/// selection. Capabilities are fetched per chosen model at connect().
/// Throws on a non-loopback endpoint or failed metadata — never downloads.
Future<List<LocalModelInfo>> discoverLocalModels({
  http.Client? client,
  required String endpoint,
}) async {
  final owned = client == null;
  final http.Client use = client ?? http.Client();
  try {
    final base = _validatedBase(endpoint);
    final data = await _getJson(
      use,
      Uri.parse('$base/api/tags'),
      timeout: const Duration(seconds: 20),
      maxBytes: 1024 * 1024,
      what: 'Local model list',
    );
    final result = <LocalModelInfo>[];
    for (final entry in (data['models'] as List? ?? [])) {
      if (entry is! Map) continue;
      final name = entry['name'];
      final digest = entry['digest'];
      if (name is! String ||
          name.isEmpty ||
          digest is! String ||
          digest.isEmpty) {
        continue;
      }
      result.add(LocalModelInfo(name: name, digest: digest));
    }
    return result;
  } finally {
    if (owned) use.close();
  }
}

bool _hasRemoteMarker(Map data) {
  if (data.keys.any((k) => k == 'remote_host' || k == 'remote_model')) {
    return true;
  }
  final details = data['details'];
  return details is Map &&
      details.keys.any((k) => k == 'remote_host' || k == 'remote_model');
}

List<String> _capabilitiesOf(Map data) {
  final caps = data['capabilities'];
  if (caps is! List) return const [];
  return caps.whereType<String>().toList();
}

/// Model names that suggest remote/cloud serving rather than local weights.
/// Checked before any metadata fetch, so cloud names never reach the wire.
bool _isCloudName(String model) {
  final lower = model.trim().toLowerCase();
  return lower.contains(':cloud') ||
      lower.contains('cloud/') ||
      lower.startsWith('cloud-') ||
      lower.startsWith('hf.co/') ||
      lower.contains('://');
}

/// Verifies one model is really installed locally: not a cloud name,
/// present in tags with a digest, `POST /api/show` succeeds, no remote
/// markers, and the server reports the required capability (current Ollama
/// always reports capabilities — silence is unverifiable). Never pulls.
Future<LocalModelInfo> _verifyModel(
  http.Client client,
  String base,
  String model, {
  required String needCapability,
  required String role,
}) async {
  if (_isCloudName(model)) {
    throw StateError(
      '“$model” looks like a remote/cloud model name. Only models installed on this machine are allowed.',
    );
  }
  final installed = await discoverLocalModels(client: client, endpoint: base);
  LocalModelInfo? match;
  for (final candidate in installed) {
    if (candidate.name == model || candidate.name == '$model:latest') {
      match = candidate;
      break;
    }
  }
  if (match == null) {
    throw StateError(
      '“$model” is not installed on the local server ($role). No download was started — pull it yourself first.',
    );
  }
  final shown = await _postJson(
    client,
    Uri.parse('$base/api/show'),
    {'name': match.name},
    timeout: const Duration(seconds: 20),
    maxBytes: 1024 * 1024,
    what: 'Local model check',
  );
  if (_hasRemoteMarker(shown)) {
    throw StateError(
      '“${match.name}” is served from a remote host, not this machine. Refused before sending anything.',
    );
  }
  final caps = _capabilitiesOf(shown);
  if (caps.isEmpty ||
      !caps.contains(needCapability) ||
      (needCapability == 'vision' && !caps.contains('completion'))) {
    throw StateError(
      '“${match.name}” cannot be verified for $role here (capabilities: ${caps.isEmpty ? 'none reported' : caps.join(', ')}).',
    );
  }
  return LocalModelInfo(
    name: match.name,
    digest: match.digest,
    capabilities: caps,
  );
}

/// Instructions that demand exact JSON (organizer, extractor, planner,
/// research planner/assessor, transcription) get Ollama `format: 'json'`.
/// Summaries and free conversation must stay natural language: no format.
const _jsonInstructions = {
  organizerPrompt,
  extractorPrompt,
  plannerPrompt,
  researchPlannerPrompt,
  researchAssessorPrompt,
  transcriptionPrompt,
};

class WebIntelligence extends LocalIntelligence {
  WebIntelligence({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  /// Discovery and verification share this bridge's client and local-only rules.
  Future<List<LocalModelInfo>> discoverInstalledModels({String? endpoint}) =>
      discoverLocalModels(client: _client, endpoint: endpoint ?? this.endpoint);

  /// Base URL of the local model server. Loopback `http` only.
  String endpoint = 'http://127.0.0.1:11434';

  /// Local chat model name, e.g. `qwen3:8b`. Empty means not configured.
  String chatModel = '';

  /// Optional local vision model name for scan transcription.
  String visionModel = '';

  LocalModelInfo? chatInfo, visionInfo;
  String? _chatEndpoint, _verifiedChat, _visionEndpoint, _verifiedVision;

  /// Connected means verified: the exact current endpoint + model passed
  /// `connect()`. Merely configured (never verified, or edited since) is
  /// NOT connected, so the UI must not present it as ready.
  @override
  bool get available {
    final current = chatModel.trim();
    if (current.isEmpty || _verifiedChat != current) return false;
    try {
      return _chatEndpoint == _validatedBase(endpoint);
    } catch (_) {
      return false;
    }
  }

  bool get visionAvailable {
    final current = visionModel.trim();
    if (current.isEmpty || _verifiedVision != current) return false;
    try {
      return _visionEndpoint == _validatedBase(endpoint);
    } catch (_) {
      return false;
    }
  }

  /// Verifies the configured endpoint + models against live local metadata.
  /// [generate]/[transcribeBytes] re-verify before every call (see below).
  /// All-empty roles disconnect instead of throwing, so keyword-only mode
  /// stays usable. Never downloads or pulls models.
  Future<void> connect({
    String? endpoint,
    String? chatModel,
    String? visionModel,
  }) async {
    if (endpoint != null) this.endpoint = endpoint;
    if (chatModel != null) this.chatModel = chatModel;
    if (visionModel != null) this.visionModel = visionModel;
    final chat = this.chatModel.trim();
    final vision = this.visionModel.trim();
    if (chat.isEmpty && vision.isEmpty) {
      _clearChat();
      _clearVision();
      return;
    }
    final base = _validatedBase(this.endpoint);
    if (chat.isNotEmpty) {
      final meta = await _checkChat(base, chat);
      _chatEndpoint = base;
      _verifiedChat = chat;
      chatInfo = meta;
    } else {
      _clearChat();
    }
    if (vision.isNotEmpty) {
      final meta = await _checkVision(base, vision);
      _visionEndpoint = base;
      _verifiedVision = vision;
      visionInfo = meta;
    } else {
      _clearVision();
    }
  }

  Future<LocalModelInfo> _checkChat(String base, String name) async {
    try {
      return await _verifyModel(
        _client,
        base,
        name,
        needCapability: 'completion',
        role: 'chat',
      );
    } catch (_) {
      _clearChat();
      rethrow;
    }
  }

  Future<LocalModelInfo> _checkVision(String base, String name) async {
    try {
      return await _verifyModel(
        _client,
        base,
        name,
        needCapability: 'vision',
        role: 'vision transcription',
      );
    } catch (_) {
      _clearVision();
      rethrow;
    }
  }

  void _clearChat() {
    // Role-scoped: a failed chat check never touches vision status.
    _chatEndpoint = null;
    _verifiedChat = null;
    chatInfo = null;
  }

  void _clearVision() {
    _visionEndpoint = null;
    _verifiedVision = null;
    visionInfo = null;
  }

  /// Re-verifies the chat model against live metadata before every
  /// health-bearing call. Catches alias retargeting, removed/changed
  /// weights, and newly remote serving; any failure clears the stored
  /// verification instead of retaining a stale success.
  Future<String> _liveChatBase() async {
    late final String base;
    try {
      base = _validatedBase(endpoint);
    } catch (_) {
      _clearChat();
      rethrow;
    }
    final name = chatModel.trim();
    if (name.isEmpty || _verifiedChat != name) {
      _clearChat();
      throw StateError(
        'Connect and verify the local chat model first — unverified models never receive report content.',
      );
    }
    final meta = await _checkChat(base, name);
    if (chatInfo != null && meta.digest != chatInfo!.digest) {
      _clearChat();
      throw StateError(
        'The local chat weights changed since verification. Reconnect before sending anything.',
      );
    }
    _chatEndpoint = base;
    _verifiedChat = name;
    chatInfo = meta;
    return base;
  }

  /// Same live re-verification for the vision model before every image.
  Future<String> _liveVisionBase() async {
    late final String base;
    try {
      base = _validatedBase(endpoint);
    } catch (_) {
      _clearVision();
      rethrow;
    }
    final name = visionModel.trim();
    if (name.isEmpty || _verifiedVision != name) {
      _clearVision();
      throw StateError(
        'Connect and verify the local vision model first — unverified models never receive images.',
      );
    }
    final meta = await _checkVision(base, name);
    if (visionInfo != null && meta.digest != visionInfo!.digest) {
      _clearVision();
      throw StateError(
        'The local vision weights changed since verification. Reconnect before sending anything.',
      );
    }
    _visionEndpoint = base;
    _verifiedVision = name;
    visionInfo = meta;
    return base;
  }

  @override
  Future<void> configure(String localPath, String family) {
    throw StateError(
      'Model files are installed in the mobile app. This client uses your localhost model server instead.',
    );
  }

  @override
  Future<String> generate(String instruction, String input) async {
    if (instruction.length + input.length > 100000) {
      throw const FormatException(
        'The local request exceeded the safety limit.',
      );
    }
    final base = await _liveChatBase();
    final body = <String, dynamic>{
      'model': _verifiedChat,
      'system': instruction,
      'prompt': input,
      'stream': false,
      'options': {'temperature': 0, 'num_predict': 4096},
    };
    if (_jsonInstructions.contains(instruction)) {
      body['format'] = 'json';
      // Routine schema-filling must not burn the output budget (or cold
      // minutes) on hidden thought — but only when the verified model
      // actually thinks. Summaries and conversation keep the default.
      if (chatInfo?.capabilities.contains('thinking') ?? false) {
        body['think'] = false;
      }
    }
    late final String text;
    try {
      final data = await _postJson(
        _client,
        Uri.parse('$base/api/generate'),
        body,
        timeout: const Duration(minutes: 5),
        maxBytes: 2 * 1024 * 1024,
        what: 'Local inference',
      );
      if (data['done'] == false || data['done_reason'] == 'length') {
        throw const FormatException(
          'The local output was cut off before finishing. Retry once the model is ready.',
        );
      }
      text = (data['response'] as String? ?? '').trim();
      if (text.isEmpty) throw const FormatException('Empty local response.');
    } catch (_) {
      _clearChat();
      rethrow;
    }
    return text;
  }

  @override
  Future<List<String>> transcribeImage(Uint8List bytes) =>
      transcribeBytes(bytes);

  /// Transcribes a scan/photo with the verified local vision model.
  Future<List<String>> transcribeBytes(List<int> bytes) async {
    if (bytes.length > 15 * 1024 * 1024) {
      throw const FormatException('The image exceeded the local safety limit.');
    }
    final base = await _liveVisionBase();
    late final List<String> lines;
    try {
      final body = <String, dynamic>{
        'model': _verifiedVision,
        'system': transcriptionPrompt,
        'prompt': 'Transcribe the visible English text, preserving table rows.',
        'images': [base64Encode(bytes)],
        'stream': false,
        'format': 'json',
        'options': {'temperature': 0, 'num_predict': 4096},
      };
      if (visionInfo?.capabilities.contains('thinking') ?? false) {
        body['think'] = false;
      }
      final data = await _postJson(
        _client,
        Uri.parse('$base/api/generate'),
        body,
        timeout: const Duration(minutes: 5),
        maxBytes: 2 * 1024 * 1024,
        what: 'Local vision transcription',
      );
      if (data['done'] == false || data['done_reason'] == 'length') {
        throw const FormatException(
          'The local transcription was cut off before finishing. Retry once the model is ready.',
        );
      }
      final output = ((data['response'] as String?) ?? '')
          .trim()
          .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
          .replaceFirst(RegExp(r'\s*```$'), '');
      final decoded = jsonDecode(output);
      if (decoded is! Map || decoded['lines'] is! List) {
        throw const FormatException('Invalid local transcript.');
      }
      final raw = decoded['lines'] as List;
      if (raw.length > 300 || raw.any((l) => l is! String || l.length > 2000)) {
        throw const FormatException('Invalid local transcript.');
      }
      lines = raw
          .cast<String>()
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
    } catch (_) {
      _clearVision();
      rethrow;
    }
    return lines;
  }
}

/// Local embeddings for the in-memory web client via the localhost server
/// (`/api/embed`). Same verify-first, no-redirect, loopback-only rules.
class WebEmbeddings extends LocalEmbeddings {
  WebEmbeddings({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  String endpoint = 'http://127.0.0.1:11434';

  /// Local embedding model name, e.g. `embeddinggemma-2`. Empty = not set.
  String embeddingModel = '';

  LocalModelInfo? modelInfo;
  String? _verifiedEndpoint, _verifiedModel;

  @override
  bool get available {
    final current = embeddingModel.trim();
    if (current.isEmpty || _verifiedModel != current) return false;
    try {
      return _verifiedEndpoint == _validatedBase(endpoint);
    } catch (_) {
      return false;
    }
  }

  /// Verifies the embedding model and resets the vector identity to its
  /// full digest (+ endpoint + task format), so stale vectors from different
  /// weights can never match. Empty model disconnects instead of throwing,
  /// keeping keyword-only mode usable. Never downloads or pulls models.
  Future<void> connect({String? endpoint, String? embeddingModel}) async {
    if (endpoint != null) this.endpoint = endpoint;
    if (embeddingModel != null) this.embeddingModel = embeddingModel;
    final model = this.embeddingModel.trim();
    if (model.isEmpty) {
      _clear();
      return;
    }
    final base = _validatedBase(this.endpoint);
    final meta = await _check(base, model);
    _verifiedEndpoint = base;
    _verifiedModel = model;
    modelInfo = meta;
    version = _identity(base, meta);
  }

  Future<LocalModelInfo> _check(String base, String model) async {
    try {
      return await _verifyModel(
        _client,
        base,
        model,
        needCapability: 'embedding',
        role: 'embeddings',
      );
    } catch (_) {
      _clear();
      rethrow;
    }
  }

  void _clear() {
    _verifiedEndpoint = null;
    _verifiedModel = null;
    modelInfo = null;
    version = null;
  }

  String _identity(String base, LocalModelInfo meta) {
    final task = meta.name.toLowerCase().contains('embeddinggemma')
        ? 'eg2'
        : 'std';
    return 'ollama:$base:${meta.digest}:$task';
  }

  /// Re-verifies the embedding model against live metadata before every
  /// call: a retargeted alias, changed digest, or newly remote serving
  /// clears the identity and refuses instead of scoring stale vectors.
  Future<String> _liveBase() async {
    late final String base;
    try {
      base = _validatedBase(endpoint);
    } catch (_) {
      _clear();
      rethrow;
    }
    final model = embeddingModel.trim();
    if (model.isEmpty || _verifiedModel != model) {
      _clear();
      throw StateError(
        'Connect and verify the local embedding model first — unverified models never receive report content.',
      );
    }
    final meta = await _check(base, model);
    if (modelInfo != null && meta.digest != modelInfo!.digest) {
      _clear();
      throw StateError(
        'The local embedding weights changed since verification. Reconnect before sending anything.',
      );
    }
    _verifiedEndpoint = base;
    _verifiedModel = model;
    modelInfo = meta;
    version = _identity(base, meta);
    return base;
  }

  @override
  Future<void> load(String path, String fingerprint) {
    throw StateError(
      'Model files are installed in the mobile app. This client uses your localhost model server instead.',
    );
  }

  @override
  Future<List<double>> embed(String text, {bool document = false}) async {
    var input = text.trim();
    if (input.isEmpty) throw const FormatException('Nothing to embed.');
    if (input.length > 20000) {
      throw const FormatException(
        'The local embedding input exceeded the safety limit.',
      );
    }
    final base = await _liveBase();
    final model = _verifiedModel!;
    if (model.toLowerCase().contains('embeddinggemma')) {
      input = document
          ? 'task: search result | text: $input'
          : 'task: search query | text: $input';
    }
    late final List<double> result;
    try {
      final data = await _postJson(
        _client,
        Uri.parse('$base/api/embed'),
        {'model': model, 'input': input},
        timeout: const Duration(minutes: 2),
        maxBytes: 2 * 1024 * 1024,
        what: 'Local embeddings',
      );
      final vectors = (data['embeddings'] as List?)?.firstOrNull;
      if (vectors is! List || vectors.isEmpty) {
        throw StateError('Local embeddings returned an invalid vector.');
      }
      result = vectors.map((x) => (x as num).toDouble()).toList();
      if (result.any((x) => !x.isFinite)) {
        throw StateError('Local embeddings returned an invalid vector.');
      }
    } catch (_) {
      _clear();
      rethrow;
    }
    return result;
  }
}
