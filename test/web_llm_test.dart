// Localhost-only guard tests for the web local-AI bridge.
// No network calls: refusal happens before any HTTP.

import 'package:ayumitra/services/web_llm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unconfigured models report unavailable', () {
    expect(WebIntelligence().available, isFalse);
    expect(WebEmbeddings().available, isFalse);
  });

  test('non-loopback endpoints are refused before any request', () async {
    final intelligence = WebIntelligence()..endpoint = 'https://example.org';
    intelligence.chatModel = 'somemodel';
    await expectLater(
      intelligence.generate('instruction', 'input'),
      throwsStateError,
    );
    final embeddings = WebEmbeddings()..endpoint = 'https://example.org';
    embeddings.embeddingModel = 'somemodel';
    await expectLater(embeddings.embed('text'), throwsStateError);
  });

  test('mobile-only installers explain the localhost path', () {
    expect(() => WebIntelligence().configure('x', 'y'), throwsStateError);
    expect(() => WebEmbeddings().load('x', 'y'), throwsStateError);
  });
}
