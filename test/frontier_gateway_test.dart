import 'dart:convert';

import 'package:ayumitra/services/frontier_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const key = 'synthetic-test-key';
  const input = 'Approved synthetic context';
  const instruction = 'Answer the selected request.';
  Future<String> generate(
    FrontierGateway gateway, {
    Uri? endpoint,
    String provider = 'openai',
    String? model,
    String text = input,
  }) => gateway.generate(
    endpoint: endpoint ?? FrontierGateway.providerEndpoint(provider),
    provider: provider,
    model: model ?? (provider == 'openai' ? 'gpt-6-luna' : 'claude-haiku-5-5'),
    apiKey: key,
    instruction: instruction,
    input: text,
  );
  Map<String, Object?> openAi({
    String text = 'Synthetic answer',
    String model = 'gpt-6-luna',
    String status = 'completed',
  }) => {
    'model': model,
    'status': status,
    'error': null,
    'output': [
      {
        'type': 'message',
        'role': 'assistant',
        'status': 'completed',
        'content': [
          {'type': 'output_text', 'text': text},
        ],
      },
    ],
  };
  Map<String, Object?> anthropic({
    String text = 'Synthetic answer',
    String model = 'claude-haiku-5-5',
    String stop = 'end_turn',
  }) => {
    'model': model,
    'type': 'message',
    'role': 'assistant',
    'stop_reason': stop,
    'content': [
      {'type': 'text', 'text': text},
    ],
  };
  http.Response response(Object data) => http.Response(
    jsonEncode(data),
    200,
    headers: {'content-type': 'application/json'},
  );

  test(
    'OpenAI uses direct Responses API and only the selected context',
    () async {
      final gateway = FrontierGateway(
        client: MockClient((request) async {
          expect(request.url, Uri.parse('https://api.openai.com/v1/responses'));
          expect(request.method, 'POST');
          expect(request.followRedirects, isFalse);
          expect(request.headers['Authorization'], 'Bearer $key');
          expect(request.headers.containsKey('x-api-key'), isFalse);
          expect(jsonDecode(request.body), {
            'model': 'gpt-6-luna',
            'instructions': instruction,
            'input': input,
            'max_output_tokens': 4096,
            'store': false,
          });
          return response(openAi());
        }),
      );
      expect(await generate(gateway), 'Synthetic answer');
    },
  );

  test(
    'Anthropic uses direct Messages API without browser/sampling overrides',
    () async {
      final gateway = FrontierGateway(
        client: MockClient((request) async {
          expect(
            request.url,
            Uri.parse('https://api.anthropic.com/v1/messages'),
          );
          expect(request.followRedirects, isFalse);
          expect(request.headers['x-api-key'], key);
          expect(request.headers['anthropic-version'], '2023-06-01');
          expect(request.headers.containsKey('Authorization'), isFalse);
          expect(
            request.headers.containsKey(
              'anthropic-dangerous-direct-browser-access',
            ),
            isFalse,
          );
          expect(jsonDecode(request.body), {
            'model': 'claude-haiku-5-5',
            'system': instruction,
            'messages': [
              {'role': 'user', 'content': input},
            ],
            'max_tokens': 4096,
          });
          return response(anthropic());
        }),
      );
      expect(
        await generate(gateway, provider: 'anthropic'),
        'Synthetic answer',
      );
    },
  );

  test(
    'only exact official endpoint for the selected provider receives its key',
    () async {
      var calls = 0;
      final gateway = FrontierGateway(
        client: MockClient((_) async {
          calls++;
          return response(openAi());
        }),
      );
      for (final url in [
        'https://gateway.example/v1/generate',
        'http://127.0.0.1/v1/responses',
        'https://api.openai.com.evil.example/v1/responses',
        'https://api.openai.com/v1/responses?x=1',
        'https://user:secret@api.openai.com/v1/responses',
        'https://api.openai.com/v1/responses#fragment',
        'https://api.openai.com:444/v1/responses',
        'https://api.anthropic.com/v1/messages',
      ]) {
        await expectLater(
          generate(gateway, endpoint: Uri.parse(url)),
          throwsA(isA<FrontierGatewayException>()),
        );
      }
      expect(calls, 0);
      expect(
        FrontierGateway.endpointAllowed(
          Uri.parse('https://api.openai.com/v1/responses'),
        ),
        isTrue,
      );
      expect(
        FrontierGateway.endpointAllowed(
          Uri.parse('https://api.anthropic.com/v1/messages'),
        ),
        isTrue,
      );
      expect(
        FrontierGateway.endpointAllowed(
          Uri.parse('http://127.0.0.1/v1/generate'),
        ),
        isFalse,
      );
    },
  );

  test('invalid model and oversize context never send a request', () async {
    var calls = 0;
    final gateway = FrontierGateway(
      client: MockClient((_) async {
        calls++;
        return response(openAi());
      }),
    );
    await expectLater(
      generate(gateway, model: 'openai/model'),
      throwsA(isA<FrontierGatewayException>()),
    );
    await expectLater(
      generate(gateway, text: 'x' * FrontierGateway.maxRequestBytes),
      throwsA(isA<FrontierGatewayException>()),
    );
    expect(calls, 0);
  });

  test(
    'redirects/provider errors stop after one attempt and never expose payload',
    () async {
      for (final status in [302, 401, 429, 500]) {
        var calls = 0;
        final gateway = FrontierGateway(
          client: MockClient((_) async {
            calls++;
            return http.Response(
              'raw $key synthetic-health-text',
              status,
              headers: {'location': 'https://elsewhere.example'},
            );
          }),
        );
        try {
          await generate(gateway);
          fail('expected error');
        } catch (error) {
          expect(error, isA<FrontierGatewayException>());
          expect('$error', isNot(contains(key)));
          expect('$error', isNot(contains('synthetic-health-text')));
        }
        expect(calls, 1);
      }
    },
  );

  test(
    'OpenAI rejects incomplete, refused, tool-only, empty and wrong-model output',
    () async {
      for (final data in [
        openAi(status: 'incomplete'),
        openAi(text: ''),
        openAi(model: 'other-model'),
        {
          ...openAi(),
          'output': [
            {'type': 'function_call', 'arguments': '{}'},
          ],
        },
        {
          ...openAi(),
          'output': [
            {
              'type': 'message',
              'role': 'assistant',
              'status': 'completed',
              'content': [
                {'type': 'refusal', 'refusal': 'refused'},
              ],
            },
          ],
        },
        {...openAi(), 'output': []},
        {
          ...openAi(),
          'error': {'message': 'private'},
        },
      ]) {
        final gateway = FrontierGateway(
          client: MockClient((_) async => response(data)),
        );
        await expectLater(
          generate(gateway),
          throwsA(isA<FrontierGatewayException>()),
        );
      }
    },
  );

  test(
    'Anthropic rejects truncated, tool, refusal, empty and wrong-model output',
    () async {
      for (final data in [
        anthropic(stop: 'max_tokens'),
        anthropic(stop: 'tool_use'),
        anthropic(stop: 'refusal'),
        anthropic(text: ''),
        anthropic(model: 'other-model'),
        {
          ...anthropic(),
          'content': [
            {'type': 'tool_use', 'id': 'x'},
          ],
        },
        {
          ...anthropic(),
          'content': [
            {'type': 'refusal', 'text': 'refused'},
          ],
        },
      ]) {
        final gateway = FrontierGateway(
          client: MockClient((_) async => response(data)),
        );
        await expectLater(
          generate(gateway, provider: 'anthropic'),
          throwsA(isA<FrontierGatewayException>()),
        );
      }
    },
  );

  test(
    'reasoning blocks are excluded and same-model dated snapshots accepted',
    () async {
      final gateway = FrontierGateway(
        client: MockClient(
          (_) async => response({
            ...openAi(model: 'gpt-6-luna-2026-10-01'),
            'output': [
              {
                'type': 'reasoning',
                'summary': [
                  {'type': 'summary_text', 'text': 'PRIVATE_REASONING'},
                ],
              },
              ...(openAi()['output'] as List),
            ],
          }),
        ),
      );
      expect(await generate(gateway), 'Synthetic answer');
    },
  );

  test(
    'invalid JSON, content type and oversized responses are generic failures',
    () async {
      for (final reply in [
        http.Response(
          'not json',
          200,
          headers: {'content-type': 'application/json'},
        ),
        http.Response('<html>text</html>', 200),
        http.Response(
          'x' * (FrontierGateway.maxResponseBytes + 1),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ]) {
        final gateway = FrontierGateway(client: MockClient((_) async => reply));
        await expectLater(
          generate(gateway),
          throwsA(isA<FrontierGatewayException>()),
        );
      }
    },
  );

  test('network exceptions never expose credentials', () async {
    final gateway = FrontierGateway(
      client: MockClient((_) async => throw Exception(key)),
    );
    try {
      await generate(gateway);
      fail('expected error');
    } catch (error) {
      expect('$error', isNot(contains(key)));
      expect(error, isA<FrontierGatewayException>());
    }
  });

  test('truncated HTTP bodies are rejected', () async {
    final client = _StreamClient(
      (_) => http.StreamedResponse(
        Stream.value(utf8.encode('{}')),
        200,
        contentLength: 200,
        headers: {'content-type': 'application/json'},
      ),
    );
    await expectLater(
      generate(FrontierGateway(client: client)),
      throwsA(isA<FrontierGatewayException>()),
    );
  });
}

class _StreamClient extends http.BaseClient {
  _StreamClient(this.response);
  final http.StreamedResponse Function(http.BaseRequest) response;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response(request);
}
