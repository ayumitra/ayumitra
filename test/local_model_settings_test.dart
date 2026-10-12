import 'dart:convert';

import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/services/web_llm.dart';
import 'package:ayumitra/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _chat = 'qwen3:8b';
const _vision = 'gemma3:4b';
const _search = 'embeddinggemma-2:latest';
const _proxy = 'proxy-local:latest';

class _MetadataServer {
  final requests = <http.Request>[];
  late final client = MockClient((request) async {
    requests.add(request);
    expect(request.url.host, '127.0.0.1');
    expect(request.followRedirects, false);
    expect(['/api/tags', '/api/show'], contains(request.url.path));
    if (request.url.path == '/api/tags') {
      return http.Response(
        jsonEncode({
          'models': [
            for (final name in [_chat, _vision, _search, _proxy])
              {'name': name, 'digest': 'synthetic-digest-$name'},
          ],
        }),
        200,
      );
    }
    final model = (jsonDecode(request.body) as Map)['name'];
    return http.Response(
      jsonEncode({
        'capabilities': model == _search
            ? ['embedding']
            : ['completion', 'vision'],
        if (model == _proxy) 'remote_host': 'https://cloud.example',
      }),
      200,
    );
  });
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> _finishMetadata(
  WidgetTester tester,
  _MetadataServer server,
) async {
  // Networking futures can settle without scheduling an additional frame.
  // Wait for the visible activity to complete, not merely frame quiescence.
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (find.text('Checking local models…').evaluate().isEmpty) break;
  }
  expect(
    find.text('Checking local models…'),
    findsNothing,
    reason:
        'Metadata check did not finish. Requests: ${server.requests.map((r) => '${r.method} ${r.url}').join(', ')}',
  );
  await tester.pumpAndSettle();
}

Future<void> _connect(WidgetTester tester, _MetadataServer server) async {
  await tester.pump();
  final button = find.text('Connect local models');
  await tester.ensureVisible(button);
  await tester.tap(button);
  await _finishMetadata(tester, server);
}

Future<DemoController> _showSettings(
  WidgetTester tester,
  _MetadataServer server, {
  String chat = '',
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = DemoController(
    intelligence: WebIntelligence(client: server.client)..chatModel = chat,
    embeddings: WebEmbeddings(client: server.client),
  );
  await controller.initialize();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(home: SettingsScreen(controller: controller)),
  );
  return controller;
}

void main() {
  testWidgets(
    'configured model stays unverified; discovery and chat-only connection use metadata only',
    (tester) async {
      final server = _MetadataServer();
      final controller = await _showSettings(tester, server, chat: _chat);
      final intelligence = controller.intelligence as WebIntelligence;
      expect(find.textContaining('Chat: not connected'), findsOneWidget);
      expect(intelligence.available, false);
      expect(server.requests, isEmpty);
      await tester.enterText(_field('Chat model'), _chat);
      expect(server.requests, isEmpty);

      await tester.ensureVisible(find.text('Find installed models'));
      await tester.tap(find.text('Find installed models'));
      await _finishMetadata(tester, server);
      expect(server.requests, isNotEmpty);
      expect(find.byTooltip('Choose an installed model'), findsNWidgets(3));
      await tester.tap(find.byTooltip('Choose an installed model').first);
      await tester.pumpAndSettle();
      expect(find.text(_chat), findsWidgets);
      expect(find.text(_vision), findsOneWidget);
      expect(find.text(_search), findsOneWidget);
      await tester.tap(find.text(_chat).last);
      await tester.pumpAndSettle();
      expect(intelligence.available, false);
      expect(find.textContaining('Chat: not connected'), findsOneWidget);

      await _connect(tester, server);
      expect(intelligence.available, true);
      expect(intelligence.visionAvailable, false);
      expect(find.textContaining('Chat: connected ($_chat)'), findsOneWidget);
      expect(
        find.text('Selected models verified on this computer.'),
        findsOneWidget,
      );
      expect(
        server.requests.any((request) => request.url.path == '/api/show'),
        true,
      );
      expect(
        server.requests.every(
          (request) =>
              !request.body.contains('prompt') &&
              !request.body.contains('images'),
        ),
        true,
      );
    },
  );

  testWidgets(
    'verified chat, vision and search roles connect without sending document content',
    (tester) async {
      final server = _MetadataServer();
      final controller = await _showSettings(tester, server);
      await tester.enterText(_field('Chat model'), _chat);
      await tester.enterText(_field('Vision model (optional)'), _vision);
      await tester.enterText(
        _field('Search model (EmbeddingGemma 2)'),
        _search,
      );
      expect(server.requests, isEmpty);
      await _connect(tester, server);
      expect(controller.intelligence.available, true);
      expect(
        (controller.intelligence as WebIntelligence).visionAvailable,
        true,
      );
      expect(controller.embeddings.available, true);
      expect(find.textContaining('Vision: verified'), findsOneWidget);
      expect(find.textContaining('Search: verified'), findsOneWidget);
      expect(
        server.requests
            .where((request) => request.url.path == '/api/show')
            .length,
        3,
      );
      expect(
        server.requests.every(
          (request) => ['/api/tags', '/api/show'].contains(request.url.path),
        ),
        true,
      );
    },
  );

  testWidgets(
    'remote and missing models and external hosts show refusal without inference',
    (tester) async {
      final server = _MetadataServer();
      final controller = await _showSettings(tester, server);
      await tester.enterText(_field('Chat model'), _proxy);
      await _connect(tester, server);
      expect(controller.intelligence.available, false);
      expect(find.textContaining('Chat: not connected'), findsOneWidget);
      expect(
        find.textContaining(
          'The selected models could not be verified as local.',
        ),
        findsOneWidget,
      );

      await tester.enterText(_field('Chat model'), 'not-installed:latest');
      await _connect(tester, server);
      expect(controller.intelligence.available, false);
      expect(
        find.textContaining(
          'The selected models could not be verified as local.',
        ),
        findsOneWidget,
      );
      final count = server.requests.length;
      await tester.enterText(
        _field('Local server (localhost only)'),
        'https://cloud.example',
      );
      await tester.enterText(_field('Chat model'), _chat);
      await _connect(tester, server);
      expect(controller.intelligence.available, false);
      expect(server.requests.length, count);
      expect(find.textContaining('Chat: not connected'), findsOneWidget);
      expect(
        find.textContaining(
          'The selected models could not be verified as local.',
        ),
        findsOneWidget,
      );
    },
  );
}
