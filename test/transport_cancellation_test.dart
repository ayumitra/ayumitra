import 'dart:async';
import 'dart:convert';

import 'package:ayumitra/services/frontier_gateway.dart';
import 'package:ayumitra/services/task_cancellation.dart';
import 'package:ayumitra/services/web_llm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _Transport extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  Future<http.StreamedResponse> Function(http.BaseRequest)? respond;
  int closes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return respond!(request);
  }

  @override
  void close() {
    closes++;
  }
}

http.StreamedResponse _json(Object data) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(data))),
  200,
  headers: {'content-type': 'application/json'},
);
Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(ready(), isTrue);
}

void main() {
  test(
    'cloud Stop signals HTTP abort, consumes late failure, and leaves transport reusable',
    () async {
      final client = _Transport();
      final blocked = Completer<http.StreamedResponse>();
      client.respond = (_) => blocked.future;
      final gateway = FrontierGateway(client: client);
      Future<String> generate() => gateway.generate(
        endpoint: FrontierGateway.providerEndpoint('openai'),
        provider: 'openai',
        model: 'gpt-6-luna',
        apiKey: 'synthetic-key',
        instruction: 'Synthetic instruction',
        input: 'Synthetic input',
      );
      final pending = generate();
      await _until(() => client.requests.isNotEmpty);
      final request = client.requests.single as http.AbortableRequest;
      final aborted = request.abortTrigger!;
      final assertion = expectLater(pending, throwsA(isA<TaskCancelled>()));
      gateway.cancelActiveRequests();
      await assertion;
      await aborted;
      blocked.completeError(StateError('Synthetic late transport failure'));
      await Future<void>.delayed(Duration.zero);
      expect(client.closes, 0);
      client.respond = (_) async => _json({
        'model': 'gpt-6-luna',
        'status': 'completed',
        'error': null,
        'output': [
          {
            'type': 'message',
            'role': 'assistant',
            'status': 'completed',
            'content': [
              {'type': 'output_text', 'text': 'Fresh synthetic answer'},
            ],
          },
        ],
      });
      expect(await generate(), 'Fresh synthetic answer');
    },
  );
  test(
    'local bridge Stop cancels response subscription without losing model verification',
    () async {
      final client = _Transport();
      var block = true;
      var subscribed = false;
      var cancelled = false;
      final body = StreamController<List<int>>(
        onListen: () {
          subscribed = true;
        },
        onCancel: () {
          cancelled = true;
        },
      );
      client.respond = (request) async {
        switch (request.url.path) {
          case '/api/tags':
            return _json({
              'models': [
                {'name': 'synthetic:latest', 'digest': 'a' * 64},
              ],
            });
          case '/api/show':
            return _json({
              'capabilities': ['completion', 'vision'],
            });
          case '/api/generate':
            return block
                ? http.StreamedResponse(body.stream, 200)
                : _json({'response': 'Fresh local answer', 'done': true});
        }
        throw StateError('Unexpected endpoint');
      };
      final model = WebIntelligence(client: client);
      await model.connect(
        endpoint: 'http://127.0.0.1:11434',
        chatModel: 'synthetic:latest',
      );
      final pending = model.generate(
        'Synthetic instruction',
        'Synthetic input',
      );
      await _until(() => subscribed);
      final request = client.requests.last as http.AbortableRequest;
      final assertion = expectLater(pending, throwsA(isA<TaskCancelled>()));
      await model.cancelGeneration();
      await assertion;
      await request.abortTrigger!;
      await _until(() => cancelled);
      expect(model.available, isTrue);
      expect(client.closes, 0);
      block = false;
      expect(
        await model.generate('Synthetic instruction', 'New input'),
        'Fresh local answer',
      );
      await body.close();
      expect(
        client.requests.every(
          (r) => !r.url.path.contains('stop') && !r.url.path.contains('unload'),
        ),
        isTrue,
      );
    },
  );
}
