import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/local_voice.dart';
import 'package:ayumitra/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _GreetingModel extends LocalIntelligence {
  @override
  bool get available => true;
  @override
  Future<String> generate(String instruction, String input) async =>
      instruction == plannerPrompt
      ? '{"actions":[{"action":"conversation","query":""}]}'
      : 'Hello. I can help organize your saved reports.';
}

class _NativeShapeController extends DemoController {
  _NativeShapeController() : super(intelligence: _GreetingModel());
  @override
  bool get isPreview => false;
}

class _Voice extends LocalVoice {
  _Voice(void Function(String) onCommand) : super(onCommand: onCommand);
  int starts = 0, stops = 0;
  bool paused = false;
  @override
  Future<void> startPushToTalk() async {
    starts++;
    mode = VoiceMode.pushToTalk;
    listening = true;
    available = true;
    onDevice = true;
    status = 'Listening on this device…';
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stops++;
    listening = false;
    wakeEnabled = false;
    mode = VoiceMode.idle;
  }

  @override
  Future<void> suspend(bool value) async {
    paused = value;
    if (value) listening = false;
  }

  void finalCommand(String text) {
    if (!paused) onCommand(text);
    listening = false;
    notifyListeners();
  }
}

Future<(_NativeShapeController, _Voice)> _mount(WidgetTester tester) async {
  final c = _NativeShapeController();
  await c.initialize();
  await c.createProfile('Synthetic voice person', DateTime(2000), '', false);
  late _Voice voice;
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [companionRouteObserver],
      home: CompanionScreen(
        controller: c,
        voiceFactory: (callback) => voice = _Voice(callback),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(c.dispose);
  return (c, voice);
}

void main() {
  testWidgets(
    'microphone utterance submits through the normal saved conversation',
    (tester) async {
      final (c, voice) = await _mount(tester);
      await tester.tap(find.byTooltip('Speak to Ayumitra'));
      await tester.pump();
      expect(voice.starts, 1);
      expect(find.byTooltip('Stop microphone'), findsOneWidget);
      expect(find.text('Ayu'), findsNothing);
      expect(find.text('Listening on this device…'), findsNothing);
      voice.finalCommand('Hello');
      await tester.pumpAndSettle();
      expect(c.messages.first.text, 'Hello');
      expect(c.activeSession!.turns.first.text, 'Hello');
      expect(c.data.memories.single.text, contains('Hello'));
      expect(find.byTooltip('Speak to Ayumitra'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('history navigation and person changes stop voice commands', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (c, voice) = await _mount(tester);
    await tester.tap(find.byTooltip('Speak to Ayumitra'));
    await tester.pump();
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('history-section-switch')));
    await tester.pumpAndSettle();
    expect(voice.paused, true);
    expect(voice.listening, false);
    expect(find.byType(NavigationBar), findsNothing);
    voice.finalCommand('Hello');
    await tester.pumpAndSettle();
    expect(c.messages, isEmpty);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion-section-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Speak to Ayumitra'));
    await tester.pump();
    await c.createProfile('Synthetic other person', DateTime(1990), '', false);
    await tester.pumpAndSettle();
    expect(voice.stops, greaterThan(0));
    expect(voice.listening, false);
    expect(c.messages, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
