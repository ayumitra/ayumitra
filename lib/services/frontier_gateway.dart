import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/frontier_models.dart';

/// Optional direct-provider text transport. The legacy class name remains for
/// compatibility; no gateway server is involved. The controller requires the
/// saved cloud disclosure and selected cloud mode before submitting context.
class FrontierGateway {
  FrontierGateway({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const maxRequestBytes = 256 * 1024;
  static const maxResponseBytes = 512 * 1024;
  static const requestTimeout = Duration(seconds: 120);

  static Uri providerEndpoint(String provider) => switch (provider) {
    FrontierModels.openAiProvider => Uri.https(
      'api.openai.com',
      '/v1/responses',
    ),
    FrontierModels.anthropicProvider => Uri.https(
      'api.anthropic.com',
      '/v1/messages',
    ),
    _ => throw const FrontierGatewayException('Choose OpenAI or Anthropic.'),
  };

  /// Provider keys can only go to an exact official HTTPS API endpoint.
  static bool endpointAllowed(Uri endpoint) =>
      FrontierModels.providers.any((p) => endpoint == providerEndpoint(p));

  Future<String> generate({
    required Uri endpoint,
    required String provider,
    required String model,
    required String apiKey,
    required String instruction,
    required String input,
  }) async {
    if (!FrontierModels.isValidProvider(provider) ||
        endpoint != providerEndpoint(provider) ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$').hasMatch(model) ||
        apiKey.isEmpty ||
        apiKey.length > 4096 ||
        RegExp(r'\s').hasMatch(apiKey) ||
        instruction.trim().isEmpty ||
        input.trim().isEmpty) {
      throw const FrontierGatewayException(
        'Check the selected cloud model and provider key.',
      );
    }
    final body = utf8.encode(
      jsonEncode(
        provider == FrontierModels.openAiProvider
            ? {
                'model': model,
                'instructions': instruction,
                'input': input,
                'max_output_tokens': 4096,
                'store': false,
              }
            : {
                'model': model,
                'system': instruction,
                'messages': [
                  {'role': 'user', 'content': input},
                ],
                'max_tokens': 4096,
              },
      ),
    );
    if (body.length > maxRequestBytes) {
      throw const FrontierGatewayException(
        'The selected context is too large. Select fewer records.',
      );
    }
    final abort = Completer<void>();
    try {
      return await _generate(
        endpoint,
        apiKey,
        body,
        provider,
        model,
        abort.future,
      ).timeout(requestTimeout);
    } on FrontierGatewayException {
      rethrow;
    } catch (_) {
      // SDK/transport exceptions can contain credentials or health information.
      throw const FrontierGatewayException(
        'The cloud request did not finish. Your local records are saved; no fallback model was used.',
      );
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<String> _generate(
    Uri endpoint,
    String apiKey,
    List<int> body,
    String provider,
    String model,
    Future<void> abortTrigger,
  ) async {
    final request =
        http.AbortableRequest('POST', endpoint, abortTrigger: abortTrigger)
          ..followRedirects = false
          ..headers.addAll({
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            if (provider == FrontierModels.openAiProvider)
              'Authorization': 'Bearer $apiKey',
            if (provider == FrontierModels.anthropicProvider) ...{
              'x-api-key': apiKey,
              'anthropic-version': '2023-06-01',
            },
          })
          ..bodyBytes = body;
    final response = await _client.send(request).timeout(requestTimeout);
    if (response.statusCode != 200) {
      throw const FrontierGatewayException(
        'The provider could not complete this request. Check the key and exact model id.',
      );
    }
    final length = response.contentLength;
    if ((length != null && length > maxResponseBytes) ||
        !(response.headers['content-type'] ?? '').toLowerCase().startsWith(
          'application/json',
        )) {
      throw const FrontierGatewayException('Invalid provider response.');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(requestTimeout)) {
      bytes.addAll(chunk);
      if (bytes.length > maxResponseBytes) {
        throw const FrontierGatewayException('Cloud response is too large.');
      }
    }
    if (length != null && bytes.length != length) {
      throw const FrontierGatewayException('Cloud response was incomplete.');
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map || !_sameModel(model, data['model'])) {
      throw const FrontierGatewayException('Invalid provider response.');
    }
    return provider == FrontierModels.openAiProvider
        ? _openAiText(data)
        : _anthropicText(data);
  }

  // Providers may resolve a model alias to its dated snapshot. Accept only
  // that exact identifier or its date suffix, never another model/family.
  static bool _sameModel(String expected, Object? actual) =>
      actual is String &&
      (actual == expected ||
          RegExp(
            '^${RegExp.escape(expected)}-(?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{8})\$',
          ).hasMatch(actual));

  static String _openAiText(Map data) {
    if (data['status'] != 'completed' ||
        data['error'] != null ||
        data['output'] is! List) {
      throw const FrontierGatewayException(
        'The provider returned an incomplete answer.',
      );
    }
    final text = <String>[];
    for (final item in data['output'] as List) {
      if (item is! Map) {
        throw const FrontierGatewayException('Invalid provider response.');
      }
      // Reasoning items are deliberately not surfaced or used as conversation memory.
      if (item['type'] == 'reasoning') continue;
      if (item['type'] != 'message' ||
          item['role'] != 'assistant' ||
          item['status'] != 'completed' ||
          item['content'] is! List) {
        throw const FrontierGatewayException(
          'The provider returned an unsupported answer.',
        );
      }
      for (final block in item['content'] as List) {
        if (block is! Map ||
            block['type'] != 'output_text' ||
            block['text'] is! String) {
          throw const FrontierGatewayException(
            'The provider returned an unsupported answer.',
          );
        }
        text.add(block['text'] as String);
      }
    }
    return _nonempty(text);
  }

  static String _anthropicText(Map data) {
    if (data['type'] != 'message' ||
        data['role'] != 'assistant' ||
        data['stop_reason'] != 'end_turn' ||
        data['content'] is! List) {
      throw const FrontierGatewayException(
        'The provider returned an incomplete answer.',
      );
    }
    final text = <String>[];
    for (final block in data['content'] as List) {
      if (block is! Map) {
        throw const FrontierGatewayException('Invalid provider response.');
      }
      if (block['type'] == 'thinking' || block['type'] == 'redacted_thinking') {
        continue;
      }
      if (block['type'] != 'text' || block['text'] is! String) {
        throw const FrontierGatewayException(
          'The provider returned an unsupported answer.',
        );
      }
      text.add(block['text'] as String);
    }
    return _nonempty(text);
  }

  static String _nonempty(List<String> text) {
    final result = text.join('\n\n').trim();
    if (result.isEmpty) {
      throw const FrontierGatewayException(
        'The provider returned an empty answer.',
      );
    }
    return result;
  }
}

class FrontierGatewayException implements Exception {
  const FrontierGatewayException(this.message);
  final String message;
  @override
  String toString() => message;
}
