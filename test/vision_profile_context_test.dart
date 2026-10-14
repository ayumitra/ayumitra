import 'dart:convert';

import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/web_llm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _model = 'synthetic-vision:latest';
const _visible = '## Visible report\nHemoglobin 13 g/dL';

class _LocalVisionServer {
  final requests = <http.Request>[];
  final generations = <Map<String, dynamic>>[];
  bool remote = false;
  void Function()? onTags;
  String Function(int attempt)? output;
  late final client = MockClient((request) async {
    requests.add(request);
    expect(request.url.host, '127.0.0.1');
    expect(request.url.scheme, 'http');
    expect(request.followRedirects, isFalse);
    Object response;
    switch (request.url.path) {
      case '/api/tags':
        onTags?.call();
        response = {
          'models': [
            {'name': _model, 'digest': 'synthetic-local-digest'},
          ],
        };
      case '/api/show':
        response = {
          'capabilities': ['completion', 'vision'],
          if (remote) 'remote_host': 'https://remote.example',
        };
      case '/api/generate':
        final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
        generations.add(body);
        response = {
          'response': output?.call(generations.length) ?? _visible,
          'done': true,
          'done_reason': 'stop',
        };
      default:
        return http.Response('{}', 404);
    }
    return http.Response(
      jsonEncode(response),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

Map<String, dynamic> _payload(Map<String, dynamic> body) {
  final prompt = body['prompt'] as String;
  expect(prompt, startsWith('$transcriptionPrompt\n\n'));
  return Map<String, dynamic>.from(
    jsonDecode(prompt.substring(transcriptionPrompt.length).trim()) as Map,
  );
}

void main() {
  test(
    'vision context goes only to the verified local inference prompt as metadata',
    () async {
      final server = _LocalVisionServer();
      final intelligence = WebIntelligence(client: server.client);
      await intelligence.connect(visionModel: _model);
      intelligence.visionProfileContext = {
        'profileId': 'synthetic-alice',
        'dateOfBirth': '2000-01-01',
        'currentDate': '2026-10-14',
        'history': 'ALICE_METADATA_ONLY',
      };
      server.requests.clear();
      final lines = await intelligence.transcribeBytes([1, 2, 3]);
      expect(lines, ['## Visible report', 'Hemoglobin 13 g/dL']);
      expect(lines.join('\n'), isNot(contains('ALICE_METADATA_ONLY')));
      expect(lines.join('\n'), isNot(contains('2000-01-01')));
      final body = server.generations.single;
      expect(body['system'], transcriptionPrompt);
      expect(body['images'], [
        base64Encode([1, 2, 3]),
      ]);
      expect(body.containsKey('format'), isFalse);
      final payload = _payload(body);
      expect(payload['profileContext'], intelligence.visionProfileContext);
      expect(payload['metadataGuidance'], contains('not visible report text'));
      expect(
        payload['metadataGuidance'],
        contains('transcribe only what is visible'),
      );
      for (final request in server.requests.where(
        (r) => r.url.path != '/api/generate',
      )) {
        expect(request.body, isNot(contains('ALICE_METADATA_ONLY')));
        expect(request.body, isNot(contains('synthetic-alice')));
      }
    },
  );

  test(
    'vision calls snapshot nested owner context before asynchronous verification',
    () async {
      final server = _LocalVisionServer();
      final intelligence = WebIntelligence(client: server.client);
      await intelligence.connect(visionModel: _model);
      final context = <String, dynamic>{
        'profileId': 'synthetic-alice',
        'details': <String, dynamic>{'marker': 'ALICE_ONLY'},
      };
      intelligence.visionProfileContext = context;
      server.onTags = () {
        (context['details'] as Map)['marker'] = 'MUTATED_AFTER_CALL';
        intelligence.visionProfileContext = {'profileId': 'synthetic-bob'};
      };
      await intelligence.transcribeBytes([1, 2, 3]);
      expect(_payload(server.generations.single)['profileContext'], {
        'profileId': 'synthetic-alice',
        'details': {'marker': 'ALICE_ONLY'},
      });
    },
  );

  test(
    'format repairs retain the same captured context without echoing rejected text',
    () async {
      final server = _LocalVisionServer();
      final intelligence = WebIntelligence(client: server.client);
      await intelligence.connect(visionModel: _model);
      intelligence.visionProfileContext = {'profileId': 'synthetic-alice'};
      server.output = (attempt) {
        intelligence.visionProfileContext = {'profileId': 'synthetic-bob'};
        return attempt == 1
            ? List.filled(301, 'REJECTED_TRANSCRIPT_MARKER').join('\n')
            : _visible;
      };
      expect(await intelligence.transcribeBytes([1, 2, 3]), [
        '## Visible report',
        'Hemoglobin 13 g/dL',
      ]);
      expect(server.generations, hasLength(2));
      for (final body in server.generations) {
        final payload = _payload(body);
        expect(payload['profileContext'], {'profileId': 'synthetic-alice'});
        expect(body['prompt'], isNot(contains('REJECTED_TRANSCRIPT_MARKER')));
      }
      expect(_payload(server.generations.first)['outputRepair'], '');
      expect(_payload(server.generations.last)['outputRepair'], isNotEmpty);
    },
  );

  test('absent context stays null and adds no derived source rows', () async {
    final server = _LocalVisionServer();
    final intelligence = WebIntelligence(client: server.client);
    await intelligence.connect(visionModel: _model);
    expect(intelligence.visionProfileContext, isNull);
    expect(await intelligence.transcribeBytes([1]), [
      '## Visible report',
      'Hemoglobin 13 g/dL',
    ]);
    expect(_payload(server.generations.single)['profileContext'], isNull);
  });

  test(
    'a server becoming remote is rejected before image or owner context leaves',
    () async {
      final server = _LocalVisionServer();
      final intelligence = WebIntelligence(client: server.client);
      await intelligence.connect(visionModel: _model);
      intelligence.visionProfileContext = {
        'history': 'PRIVATE_SYNTHETIC_CONTEXT',
      };
      server.remote = true;
      server.requests.clear();
      await expectLater(
        intelligence.transcribeBytes([1, 2, 3]),
        throwsStateError,
      );
      expect(server.generations, isEmpty);
      for (final request in server.requests) {
        expect(request.body, isNot(contains('PRIVATE_SYNTHETIC_CONTEXT')));
        expect(request.body, isNot(contains('images')));
      }
    },
  );
}
