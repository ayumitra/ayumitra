import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/frontier_models.dart';
import 'package:ayumitra/ui/frontier_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FrontierController extends AppController {
  final saved = <String>{FrontierModels.openAiProvider};
  String? savedProvider, savedModel;
  int sends = 0;
  @override
  bool frontierKeySavedFor(String provider) => saved.contains(provider);
  @override
  Future<void> setFrontierKey(String provider, String value) async {
    saved.add(provider);
    savedProvider = provider;
  }

  @override
  Future<void> setFrontierModel(String provider, String value) async {
    savedProvider = provider;
    savedModel = value;
    frontierProvider = provider;
    frontierModel = value;
  }

  @override
  Future<void> clearFrontierKey(String provider) async {
    saved.remove(provider);
  }
}

Future<void> _mount(WidgetTester tester, _FrontierController c) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: FrontierSettings(controller: c),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _selectAnthropic(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('frontier-provider')));
  await tester.tap(find.byKey(const Key('frontier-provider')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Anthropic Claude').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('provider selection shows only its own key state and model', (
    tester,
  ) async {
    final c = _FrontierController();
    addTearDown(c.dispose);
    await _mount(tester, c);
    expect(find.text('Key saved on this device for OpenAI'), findsOneWidget);
    await _selectAnthropic(tester);
    expect(find.text('No key saved for Anthropic Claude'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('frontier-model')))
          .controller!
          .text,
      FrontierModels.defaultClaudeModel,
    );
    expect(find.text('Remove'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'saving a selected provider key retains its model and clears secret',
    (tester) async {
      final c = _FrontierController();
      addTearDown(c.dispose);
      await _mount(tester, c);
      await _selectAnthropic(tester);
      await tester.ensureVisible(find.byKey(const Key('frontier-model')));
      await tester.enterText(
        find.byKey(const Key('frontier-model')),
        'custom-claude-model',
      );
      await tester.ensureVisible(find.byKey(const Key('frontier-api-key')));
      await tester.enterText(
        find.byKey(const Key('frontier-api-key')),
        'SYNTHETIC-NOT-A-SECRET',
      );
      await tester.pump();
      final field = tester.widget<TextField>(
        find.byKey(const Key('frontier-api-key')),
      );
      expect(field.obscureText, true);
      expect(field.enableIMEPersonalizedLearning, false);
      await tester.ensureVisible(find.text('Save API key'));
      await tester.tap(find.text('Save API key'));
      await tester.pumpAndSettle();
      expect(c.savedProvider, FrontierModels.anthropicProvider);
      expect(c.savedModel, 'custom-claude-model');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('frontier-api-key')))
            .controller!
            .text,
        isEmpty,
      );
      expect(c.sends, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'key-only settings disclose direct provider exposure and fit a phone',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = _FrontierController();
      addTearDown(c.dispose);
      await _mount(tester, c);
      expect(
        find.textContaining('Saving a key does not enable cloud fallback'),
        findsOneWidget,
      );
      expect(
        find.textContaining('provider receives them directly'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('frontier-gateway')), findsNothing);
      expect(find.text('Save gateway'), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('frontier-model')));
      await tester.enterText(
        find.byKey(const Key('frontier-model')),
        'custom-openai-model',
      );
      await tester.pump();
      await tester.ensureVisible(find.text('Save provider and model'));
      await tester.tap(find.text('Save provider and model'));
      await tester.pumpAndSettle();
      expect(c.savedProvider, FrontierModels.openAiProvider);
      expect(c.savedModel, 'custom-openai-model');
      expect(c.sends, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
