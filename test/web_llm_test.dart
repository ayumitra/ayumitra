// Strict-local bridge tests for the web local-AI bridge (MSG-054).
// All HTTP is mocked; no network calls, no real models, no downloads.

import 'dart:async';
import 'dart:convert';

import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/local_research.dart';
import 'package:ayumitra/services/web_llm.dart';
import 'package:ayumitra/domain/agent_plan.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _endpoint = 'http://127.0.0.1:11434';
const _chatDigest =
    'aaabbbcccdddeeefff000111222333444555666777888999000111222333444';
const _embedDigest =
    '969600aaabbbcccdddeeefff000111222333444555666777888999000111222';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _tags(List<Map<String, String>> models) => {
  'models': models,
};

/// Mock localhost server. [showFor] maps model name → /api/show body.
/// [generateStatus]/[generateBody] control /api/generate; [embedBody] (or
/// raw [rawEmbedBody] wire text, which bypasses jsonEncode) controls
/// /api/embed. Every request URL + POST body is recorded.
MockClient _server({
  required List<String> urls,
  required List<Map<String, dynamic>> posts,
  List<Map<String, String>> tags = const [],
  Map<String, Map<String, dynamic>> showFor = const {},
  int generateStatus = 200,
  Map<String, dynamic>? generateBody,
  Map<String, dynamic>? embedBody,
  String? rawEmbedBody,
}) => MockClient((request) async {
  urls.add(request.url.toString());
  if (request.method == 'POST') {
    posts.add(jsonDecode(request.body) as Map<String, dynamic>);
  }
  final path = request.url.path;
  if (path == '/api/tags') return _json(_tags(tags));
  if (path == '/api/show') {
    final name = (posts.last)['name'] as String?;
    final body = showFor[name];
    if (body == null) return _json({'error': 'not found'}, 404);
    return _json(body);
  }
  if (path == '/api/generate') {
    return _json(generateBody ?? {'response': 'ok'}, generateStatus);
  }
  if (path == '/api/embed') {
    if (rawEmbedBody != null) {
      return http.Response(
        rawEmbedBody,
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return _json(
      embedBody ??
          {
            'embeddings': [
              [0.1, 0.2],
            ],
          },
    );
  }
  return _json({'error': 'unknown'}, 404);
});

const _chatTags = [
  {'name': 'qwen3:8b', 'digest': _chatDigest},
];
const _chatShow = {
  'qwen3:8b': {
    'details': {'format': 'gguf'},
    'capabilities': ['completion', 'tools', 'thinking'],
  },
};
const _embedTags = [
  {'name': 'embeddinggemma-2:latest', 'digest': _embedDigest},
];
const _embedShow = {
  'embeddinggemma-2:latest': {
    'details': {'format': 'gguf'},
    'capabilities': ['embedding', 'vision', 'audio'],
  },
};
const _visionTags = [
  {'name': 'vision-thinker:latest', 'digest': _chatDigest},
  {'name': 'vision-plain:latest', 'digest': _embedDigest},
];
const _visionShow = {
  'vision-thinker:latest': {
    'capabilities': ['completion', 'vision', 'thinking'],
  },
  'vision-plain:latest': {
    'capabilities': ['completion', 'vision'],
  },
};
const _plainChatTags = [
  {'name': 'plain-chat:latest', 'digest': _chatDigest},
];
const _plainChatShow = {
  'plain-chat:latest': {
    'capabilities': ['completion'],
  },
};

void main() {
  test('configured but never verified is not connected', () async {
    final urls = <String>[];
    final posts = <Map<String, dynamic>>[];
    final intelligence = WebIntelligence(
      client: _server(
        urls: urls,
        posts: posts,
        tags: _chatTags,
        showFor: _chatShow,
      ),
    )..chatModel = 'qwen3:8b';
    expect(intelligence.available, isFalse);
    await expectLater(
      intelligence.generate('instruction', 'input'),
      throwsStateError,
    );
    expect(urls, isEmpty);
  });

  test('endpoint shapes are refused before any request', () async {
    for (final bad in [
      'https://127.0.0.1:11434',
      'http://user:pw@127.0.0.1:11434',
      'http://127.0.0.1:11434?q=1',
      'http://127.0.0.1:11434/#frag',
      'http://127.0.0.1:11434/v1',
      'http://example.org',
      'not a url',
    ]) {
      final urls = <String>[];
      final posts = <Map<String, dynamic>>[];
      final intelligence = WebIntelligence(
        client: _server(urls: urls, posts: posts),
      );
      await expectLater(
        intelligence.connect(endpoint: bad, chatModel: 'qwen3:8b'),
        throwsA(anything),
        reason: bad,
      );
      expect(urls, isEmpty, reason: bad);
      await expectLater(
        discoverLocalModels(
          client: _server(urls: urls, posts: posts),
          endpoint: bad,
        ),
        throwsA(anything),
        reason: bad,
      );
    }
  });

  test('uninstalled models never receive content and pull nothing', () async {
    final urls = <String>[];
    final posts = <Map<String, dynamic>>[];
    final intelligence = WebIntelligence(
      client: _server(urls: urls, posts: posts, tags: const []),
    );
    await expectLater(
      intelligence.connect(chatModel: 'missing-model'),
      throwsStateError,
    );
    expect(intelligence.available, isFalse);
    expect(urls, ['$_endpoint/api/tags']);
    expect(urls.any((u) => u.endsWith('/api/generate')), isFalse);
  });

  test('remote-fronted models are refused before any private POST', () async {
    final urls = <String>[];
    final posts = <Map<String, dynamic>>[];
    final intelligence = WebIntelligence(
      client: _server(
        urls: urls,
        posts: posts,
        tags: const [
          {'name': 'cloud-proxy:latest', 'digest': _chatDigest},
        ],
        showFor: const {
          'cloud-proxy:latest': {
            'details': {'remote_host': 'https://cloud.example'},
            'capabilities': ['completion'],
          },
        },
      ),
    );
    await expectLater(
      intelligence.connect(chatModel: 'cloud-proxy:latest'),
      throwsStateError,
    );
    expect(intelligence.available, isFalse);
    await expectLater(
      intelligence.generate('instruction', 'health content'),
      throwsStateError,
    );
    expect(urls.any((u) => u.endsWith('/api/generate')), isFalse);
  });

  test('verified local metadata enables inference with real options', () async {
    final urls = <String>[];
    final posts = <Map<String, dynamic>>[];
    final intelligence = WebIntelligence(
      client: _server(
        urls: urls,
        posts: posts,
        tags: _chatTags,
        showFor: _chatShow,
        generateBody: const {'response': '  hello  '},
      ),
    );
    await intelligence.connect(chatModel: 'qwen3:8b');
    expect(intelligence.available, isTrue);
    expect(intelligence.chatInfo?.digest, _chatDigest);
    expect(await intelligence.generate('instruction', 'input'), 'hello');
    final body = posts.lastWhere(
      (p) => p.containsKey('prompt') && !(p.containsKey('images')),
    );
    expect(body['model'], 'qwen3:8b');
    expect(body['stream'], isFalse);
    expect(body.containsKey('temperature'), isFalse);
    expect((body['options'] as Map)['temperature'], 0);
    expect((body['options'] as Map)['num_predict'], 4096);
  });

  test('editing the model after connect unverifies it', () async {
    final urls = <String>[];
    final posts = <Map<String, dynamic>>[];
    final intelligence = WebIntelligence(
      client: _server(
        urls: urls,
        posts: posts,
        tags: _chatTags,
        showFor: _chatShow,
      ),
    );
    await intelligence.connect(chatModel: 'qwen3:8b');
    expect(intelligence.available, isTrue);
    final calls = urls.length;
    intelligence.chatModel = 'something-else';
    expect(intelligence.available, isFalse);
    await expectLater(
      intelligence.generate('instruction', 'input'),
      throwsStateError,
    );
    expect(urls.length, calls);
  });

  test('redirects are rejected and never followed off-device', () async {
    final urls = <String>[];
    final posts = <Map<String, dynamic>>[];
    var redirect = false;
    final client = MockClient((request) async {
      urls.add(request.url.toString());
      if (request.method == 'POST') {
        posts.add(jsonDecode(request.body) as Map<String, dynamic>);
      }
      if (request.url.path == '/api/tags') return _json(_tags(_chatTags));
      if (request.url.path == '/api/show') return _json(_chatShow['qwen3:8b']!);
      if (request.url.path == '/api/generate') {
        if (redirect) {
          return http.Response(
            '',
            307,
            headers: {'location': 'https://evil.test/collect'},
          );
        }
        return _json(const {'response': 'fine'});
      }
      return _json(const {'error': 'unknown'}, 404);
    });
    final intelligence = WebIntelligence(client: client);
    await intelligence.connect(chatModel: 'qwen3:8b');
    redirect = true;
    await expectLater(
      intelligence.generate('instruction', 'health content'),
      throwsStateError,
    );
    expect(urls.every((u) => u.startsWith(_endpoint)), isTrue);
  });

  test('oversized inputs and responses fail closed without sending', () async {
    final urls = <String>[];
    final posts = <Map<String, dynamic>>[];
    final intelligence = WebIntelligence(
      client: _server(
        urls: urls,
        posts: posts,
        tags: _chatTags,
        showFor: _chatShow,
      ),
    );
    await intelligence.connect(chatModel: 'qwen3:8b');
    final calls = urls.length;
    await expectLater(
      intelligence.generate('instruction', 'x' * 100001),
      throwsFormatException,
    );
    expect(urls.length, calls);
  });

  test('vision requires its own verified capability', () async {
    final urls = <String>[];
    final posts = <Map<String, dynamic>>[];
    final intelligence = WebIntelligence(
      client: _server(
        urls: urls,
        posts: posts,
        tags: const [
          {'name': 'qwen3:8b', 'digest': _chatDigest},
        ],
        showFor: const {
          'qwen3:8b': {
            'capabilities': ['completion'],
          },
        },
      ),
    );
    await intelligence.connect(chatModel: 'qwen3:8b');
    expect(intelligence.available, isTrue);
    expect(intelligence.visionAvailable, isFalse);
    // Same weights lack the vision capability: enabling vision stays refused,
    // chat stays connected, and no image ever leaves the device.
    await expectLater(
      intelligence.connect(visionModel: 'qwen3:8b'),
      throwsStateError,
    );
    expect(intelligence.available, isTrue);
    expect(intelligence.visionAvailable, isFalse);
    await expectLater(
      intelligence.transcribeBytes([1, 2, 3]),
      throwsStateError,
    );
    expect(posts.any((p) => p.containsKey('images')), isFalse);
  });

  test(
    'image embeddings cannot be connected as a transcription model',
    () async {
      final posts = <Map<String, dynamic>>[];
      final intelligence = WebIntelligence(
        client: _server(
          urls: <String>[],
          posts: posts,
          tags: _embedTags,
          showFor: _embedShow,
        ),
      );
      await expectLater(
        intelligence.connect(visionModel: 'embeddinggemma-2:latest'),
        throwsStateError,
      );
      expect(intelligence.visionAvailable, isFalse);
      await expectLater(
        intelligence.transcribeBytes([1, 2, 3]),
        throwsStateError,
      );
      expect(posts.any((p) => p.containsKey('images')), isFalse);
    },
  );

  test('embeddings carry digest identity and EG2 task prefixes', () async {
    final urls = <String>[];
    final posts = <Map<String, dynamic>>[];
    final embeddings = WebEmbeddings(
      client: _server(
        urls: urls,
        posts: posts,
        tags: _embedTags,
        showFor: _embedShow,
      ),
    );
    expect(embeddings.available, isFalse);
    await embeddings.connect(embeddingModel: 'embeddinggemma-2:latest');
    expect(embeddings.available, isTrue);
    expect(embeddings.version, contains(_embedDigest.substring(0, 12)));
    expect(embeddings.version, contains(':eg2'));
    expect(embeddings.version, contains(_endpoint));
    await embeddings.embed('query text');
    final queryBody = posts.last;
    expect(
      (queryBody['input'] as String).startsWith('task: search query | text: '),
      isTrue,
    );
    await embeddings.embed('doc text', document: true);
    expect(
      (posts.last['input'] as String).startsWith(
        'task: search result | text: ',
      ),
      isTrue,
    );
  });

  test('embedding identity changes with the weights', () async {
    const otherDigest =
        'bbbbbbcccdddeeefff000111222333444555666777888999000111222333';
    final embeddings = WebEmbeddings(
      client: _server(
        urls: <String>[],
        posts: <Map<String, dynamic>>[],
        tags: const [
          {'name': 'embeddinggemma-2:latest', 'digest': _embedDigest},
          {'name': 'other-embed:latest', 'digest': otherDigest},
        ],
        showFor: const {
          'embeddinggemma-2:latest': {
            'capabilities': ['embedding'],
          },
          'other-embed:latest': {
            'capabilities': ['embedding'],
          },
        },
      ),
    );
    await embeddings.connect(embeddingModel: 'embeddinggemma-2:latest');
    final first = embeddings.version;
    expect(first, contains(_embedDigest.substring(0, 12)));
    await embeddings.connect(embeddingModel: 'other-embed:latest');
    expect(embeddings.version, isNot(first));
    expect(embeddings.version, contains(otherDigest.substring(0, 12)));
  });

  test('bad embedding payloads fail closed', () async {
    Future<WebEmbeddings> connected({
      Map<String, dynamic>? embedBody,
      String? rawEmbedBody,
    }) async {
      final embeddings = WebEmbeddings(
        client: _server(
          urls: <String>[],
          posts: <Map<String, dynamic>>[],
          tags: _embedTags,
          showFor: _embedShow,
          embedBody: embedBody,
          rawEmbedBody: rawEmbedBody,
        ),
      );
      await embeddings.connect(embeddingModel: 'embeddinggemma-2:latest');
      return embeddings;
    }

    await expectLater(
      (await connected(embedBody: const {'embeddings': []})).embed('x'),
      throwsStateError,
    );
    await expectLater(
      (await connected(embedBody: const {'nope': 1})).embed('x'),
      throwsStateError,
    );
    // Wire-real out-of-range exponents decode to non-finite doubles, which
    // the bridge rejects. Raw text bypasses jsonEncode (which cannot
    // represent Infinity) exactly like a real HTTP body would.
    await expectLater(
      (await connected(
        rawEmbedBody: '{"embeddings":[[1e400, 0.5]]}',
      )).embed('x'),
      throwsStateError,
    );
    await expectLater(
      (await connected(
        embedBody: const {
          'embeddings': [
            [
              [1.0],
            ],
          ],
        },
      )).embed('x'),
      throwsA(anything),
    );
  });

  test('down servers verify nothing and connect nothing', () async {
    final intelligence = WebIntelligence(
      client: MockClient((_) async => throw http.ClientException('down')),
    );
    await expectLater(
      intelligence.connect(chatModel: 'qwen3:8b'),
      throwsA(anything),
    );
    expect(intelligence.available, isFalse);
  });

  test('mobile-only installers explain the localhost path', () {
    expect(() => WebIntelligence().configure('x', 'y'), throwsStateError);
    expect(() => WebEmbeddings().load('x', 'y'), throwsStateError);
  });

  test('discovery lists installed names and digests only', () async {
    final models = await discoverLocalModels(
      client: _server(
        urls: <String>[],
        posts: <Map<String, dynamic>>[],
        tags: [
          ..._chatTags,
          ..._embedTags,
          {'name': 'broken-entry', 'digest': ''},
        ],
      ),
      endpoint: _endpoint,
    );
    expect(models.map((m) => m.name), ['qwen3:8b', 'embeddinggemma-2:latest']);
    expect(models.first.digest, _chatDigest);
  });

  test('IPv6 loopback keeps its brackets; bare ::1 is refused', () async {
    final urls = <String>[];
    final models = await discoverLocalModels(
      client: _server(
        urls: urls,
        posts: <Map<String, dynamic>>[],
        tags: _chatTags,
      ),
      endpoint: 'http://[::1]:11434',
    );
    expect(urls.single, 'http://[::1]:11434/api/tags');
    expect(models.single.name, 'qwen3:8b');
    await expectLater(
      discoverLocalModels(
        client: _server(urls: urls, posts: <Map<String, dynamic>>[]),
        endpoint: 'http://::1',
      ),
      throwsFormatException,
    );
  });

  test('cloud-style names are refused before any request', () async {
    for (final cloud in ['qwen3:cloud', 'cloud/qwen3', 'hf.co/qwen3']) {
      final urls = <String>[];
      final intelligence = WebIntelligence(
        client: _server(urls: urls, posts: <Map<String, dynamic>>[]),
      );
      await expectLater(
        intelligence.connect(chatModel: cloud),
        throwsStateError,
        reason: cloud,
      );
      expect(urls, isEmpty, reason: cloud);
    }
  });

  test('models reporting no capabilities are unverifiable', () async {
    final intelligence = WebIntelligence(
      client: _server(
        urls: <String>[],
        posts: <Map<String, dynamic>>[],
        tags: _chatTags,
        showFor: const {
          'qwen3:8b': {
            'details': {'format': 'gguf'},
          },
        },
      ),
    );
    await expectLater(
      intelligence.connect(chatModel: 'qwen3:8b'),
      throwsStateError,
    );
    expect(intelligence.available, isFalse);
  });

  test('empty roles disconnect instead of throwing', () async {
    final urls = <String>[];
    final posts = <Map<String, dynamic>>[];
    final intelligence = WebIntelligence(
      client: _server(
        urls: urls,
        posts: posts,
        tags: _chatTags,
        showFor: _chatShow,
      ),
    );
    await intelligence.connect(chatModel: 'qwen3:8b');
    expect(intelligence.available, isTrue);
    final calls = urls.length;
    await intelligence.connect(chatModel: '', visionModel: '');
    expect(intelligence.available, isFalse);
    expect(urls.length, calls);

    final embeddings = WebEmbeddings(
      client: _server(
        urls: <String>[],
        posts: <Map<String, dynamic>>[],
        tags: _embedTags,
        showFor: _embedShow,
      ),
    );
    await embeddings.connect(embeddingModel: 'embeddinggemma-2:latest');
    expect(embeddings.available, isTrue);
    await embeddings.connect(embeddingModel: '');
    expect(embeddings.available, isFalse);
    expect(embeddings.version, isNull);
  });

  test('retargeted alias digest stops the next private call', () async {
    var digest = _chatDigest;
    final urls = <String>[];
    MockClient server() => MockClient((request) async {
      urls.add(request.url.toString());
      if (request.url.path == '/api/tags') {
        return _json(
          _tags([
            {'name': 'qwen3:8b', 'digest': digest},
          ]),
        );
      }
      if (request.url.path == '/api/show') {
        return _json(_chatShow['qwen3:8b']!);
      }
      return _json(const {'response': 'should never arrive'});
    });
    final intelligence = WebIntelligence(client: server());
    await intelligence.connect(chatModel: 'qwen3:8b');
    expect(intelligence.available, isTrue);
    digest = _embedDigest; // Same alias, different weights behind it.
    final generates = urls.where((u) => u.endsWith('/api/generate')).length;
    await expectLater(
      intelligence.generate('instruction', 'health content'),
      throwsStateError,
    );
    expect(intelligence.available, isFalse);
    expect(urls.where((u) => u.endsWith('/api/generate')).length, generates);
  });

  test('a server that dies takes its verification with it', () async {
    var down = false;
    final client = MockClient((request) async {
      if (down) throw http.ClientException('gone');
      if (request.url.path == '/api/tags') return _json(_tags(_chatTags));
      if (request.url.path == '/api/show') {
        return _json(_chatShow['qwen3:8b']!);
      }
      return _json(const {'response': 'fine'});
    });
    final intelligence = WebIntelligence(client: client);
    await intelligence.connect(chatModel: 'qwen3:8b');
    expect(intelligence.available, isTrue);
    down = true;
    await expectLater(
      intelligence.generate('instruction', 'input'),
      throwsA(anything),
    );
    expect(intelligence.available, isFalse);
  });

  test('stalled response bodies time out and disconnect', () {
    fakeAsync((async) {
      var stall = false;
      final backing = MockClient((request) async {
        if (request.url.path == '/api/tags') return _json(_tags(_chatTags));
        if (request.url.path == '/api/show') {
          return _json(_chatShow['qwen3:8b']!);
        }
        return _json(const {'response': 'fine'});
      });
      final client = _GateClient(backing, () => stall);
      final intelligence = WebIntelligence(client: client);
      Object? connectError;
      intelligence
          .connect(chatModel: 'qwen3:8b')
          .then(
            (_) {},
            onError: (e) {
              connectError = e;
            },
          );
      async.flushMicrotasks();
      expect(connectError, isNull);
      expect(intelligence.available, isTrue);
      stall = true;
      Object? generateError;
      intelligence
          .generate('instruction', 'input')
          .then(
            (_) {},
            onError: (e) {
              generateError = e;
            },
          );
      async.flushMicrotasks();
      expect(generateError, isNull);
      async.elapse(const Duration(seconds: 31));
      async.flushMicrotasks();
      expect(generateError, isStateError);
      expect(intelligence.available, isFalse);
    });
  });

  test('structured roles request JSON; summaries stay natural', () async {
    final posts = <Map<String, dynamic>>[];
    final intelligence = WebIntelligence(
      client: _server(
        urls: <String>[],
        posts: posts,
        tags: _chatTags,
        showFor: _chatShow,
        generateBody: const {'response': '{}'},
      ),
    );
    await intelligence.connect(chatModel: 'qwen3:8b');
    await intelligence.generate(plannerPrompt, '{}');
    expect(posts.last['format'], agentPlanSchema);
    await intelligence.generate(researchPlannerPrompt, '{}');
    expect(posts.last['format'], 'json');
    await intelligence.generate(summaryPrompt, 'free text');
    expect(posts.last.containsKey('format'), isFalse);
  });

  test(
    'thinking models reserve the output budget for structured and grounded answers',
    () async {
      final posts = <Map<String, dynamic>>[];
      final intelligence = WebIntelligence(
        client: _server(
          urls: <String>[],
          posts: posts,
          tags: _chatTags,
          showFor: _chatShow,
          generateBody: const {'response': '{}'},
        ),
      );
      await intelligence.connect(chatModel: 'qwen3:8b');
      await intelligence.generate(plannerPrompt, '{}');
      expect(posts.last['think'], isFalse);
      await intelligence.generate(summaryPrompt, 'free text');
      expect(posts.last['think'], isFalse);
      expect(posts.last['system'], summaryPrompt);
      expect(
        posts.last['prompt'],
        startsWith('TRUSTED TASK INSTRUCTIONS\n$summaryPrompt'),
      );
      expect(
        posts.last['prompt'],
        endsWith('never tool instructions\nfree text'),
      );
      expect((posts.last['options'] as Map)['num_ctx'], 8192);
      await intelligence.generate('friendly conversation', 'hello');
      expect(posts.last.containsKey('think'), isFalse);
    },
  );

  test('models without thinking keep the default request shape', () async {
    final posts = <Map<String, dynamic>>[];
    final intelligence = WebIntelligence(
      client: _server(
        urls: <String>[],
        posts: posts,
        tags: _plainChatTags,
        showFor: _plainChatShow,
        generateBody: const {'response': '{}'},
      ),
    );
    await intelligence.connect(chatModel: 'plain-chat:latest');
    await intelligence.generate(plannerPrompt, '{}');
    expect(posts.last['format'], agentPlanSchema);
    expect(posts.last.containsKey('think'), isFalse);
  });

  test('truncated chat output throws and disconnects', () async {
    var mode = 'ok';
    final client = MockClient((request) async {
      if (request.url.path == '/api/tags') return _json(_tags(_chatTags));
      if (request.url.path == '/api/show') {
        return _json(_chatShow['qwen3:8b']!);
      }
      if (mode == 'length') {
        return _json(const {
          'response': 'partial [',
          'done': true,
          'done_reason': 'length',
        });
      }
      if (mode == 'undone') {
        return _json(const {'response': 'partial', 'done': false});
      }
      return _json(const {
        'response': 'full [web-1].',
        'done': true,
        'done_reason': 'stop',
      });
    });
    final intelligence = WebIntelligence(client: client);
    await intelligence.connect(chatModel: 'qwen3:8b');
    mode = 'length';
    await expectLater(
      intelligence.generate(plannerPrompt, '{}'),
      throwsFormatException,
    );
    expect(intelligence.available, isFalse);
    await intelligence.connect(chatModel: 'qwen3:8b');
    mode = 'undone';
    await expectLater(
      intelligence.generate(plannerPrompt, '{}'),
      throwsFormatException,
    );
    expect(intelligence.available, isFalse);
  });

  test('vision think gate and truncation follow the same rules', () async {
    final posts = <Map<String, dynamic>>[];
    var truncated = false;
    final intelligence = WebIntelligence(
      client: MockClient((request) async {
        if (request.method == 'POST') {
          posts.add(jsonDecode(request.body) as Map<String, dynamic>);
        }
        if (request.url.path == '/api/tags') {
          return _json(_tags(_visionTags));
        }
        if (request.url.path == '/api/show') {
          final name = posts.last['name'] as String?;
          return _json(_visionShow[name] ?? {'error': 'not found'});
        }
        if (truncated) {
          return _json(const {
            'response': '{"lines":["par',
            'done': true,
            'done_reason': 'length',
          });
        }
        return _json(const {
          'response': '{"lines":["row one"]}',
          'done': true,
          'done_reason': 'stop',
        });
      }),
    );
    await intelligence.connect(visionModel: 'vision-thinker:latest');
    expect(intelligence.visionAvailable, isTrue);
    expect(await intelligence.transcribeBytes([1, 2, 3]), ['row one']);
    final thinkerPost = posts.lastWhere((p) => p.containsKey('images'));
    expect(thinkerPost['think'], isFalse);
    expect(thinkerPost['format'], 'json');
    expect(thinkerPost['prompt'], startsWith(transcriptionPrompt));
    truncated = true;
    await expectLater(
      intelligence.transcribeBytes([1, 2, 3]),
      throwsFormatException,
    );
    expect(intelligence.visionAvailable, isFalse);
    truncated = false;
    await intelligence.connect(visionModel: 'vision-plain:latest');
    expect(intelligence.visionAvailable, isTrue);
    expect(await intelligence.transcribeBytes([1, 2, 3]), ['row one']);
    final plainPost = posts.lastWhere((p) => p.containsKey('images'));
    expect(plainPost.containsKey('think'), isFalse);
    expect(plainPost['format'], 'json');
  });
}

/// Wraps another client and stalls response bodies on demand, so the
/// body-deadline path is testable without real network waits.
class _GateClient extends http.BaseClient {
  _GateClient(this.inner, this.stalled);
  final http.Client inner;
  final bool Function() stalled;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final streamed = await inner.send(request);
    if (stalled() && request.url.path == '/api/generate') {
      return http.StreamedResponse(
        StreamController<List<int>>().stream,
        200,
        headers: streamed.headers,
      );
    }
    return streamed;
  }
}
