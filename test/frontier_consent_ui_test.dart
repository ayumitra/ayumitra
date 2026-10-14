import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/services/local_voice.dart';
import 'package:ayumitra/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Spies at the send boundary; these checks never invoke a provider or model.
class _ConsentController extends DemoController {
  final localQuestions = <String>[];
  final cloudRequests = <FrontierRequest>[];
  final selectedQuestions = <String>[];
  int prepared = 0, disclosureWrites = 0, remoteWrites = 0;
  @override
  bool get isPreview => false;
  @override
  bool get frontierAvailable => true;
  @override
  Future<void> ask(String question) async {
    localQuestions.add(question);
  }

  @override
  Future<void> askWithSelectedModel(String question) {
    selectedQuestions.add(question);
    return super.askWithSelectedModel(question);
  }

  @override
  Future<FrontierRequest> prepareFrontierRequest(String question) {
    prepared++;
    return super.prepareFrontierRequest(question);
  }

  @override
  Future<void> sendFrontierRequest(
    FrontierRequest request, {
    int maxFormatAttempts = 10,
  }) async {
    cloudRequests.add(request);
  }

  @override
  Future<void> acceptFrontierDisclosure() async {
    disclosureWrites++;
    frontierDisclosureAccepted = true;
    notifyListeners();
  }

  @override
  Future<void> setFrontierChatMode(bool enabled) async {
    if (enabled && (!frontierDisclosureAccepted || !allowRemoteAi)) return;
    useFrontierForChat = enabled;
    notifyListeners();
  }

  @override
  Future<void> setAllowRemoteAi(bool enabled) async {
    remoteWrites++;
    allowRemoteAi = enabled;
    if (!enabled) useFrontierForChat = false;
    notifyListeners();
  }
}

class _QuietVoice extends LocalVoice {
  _QuietVoice(void Function(String) onCommand) : super(onCommand: onCommand);
  @override
  Future<void> suspend(bool value) async {}
  @override
  Future<void> stop() async {}
}

Finder get _question => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.hintText == 'Talk to Ayumitra…',
);
Future<_ConsentController> _mount(
  WidgetTester tester, {
  bool acknowledged = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = _ConsentController();
  addTearDown(c.dispose);
  await c.initialize();
  c.frontierDisclosureAccepted = acknowledged;
  c.allowRemoteAi = true;
  await c.createProfile(
    'Synthetic owner',
    DateTime(2000),
    'SYNTHETIC OWNED HISTORY',
    false,
  );
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [companionRouteObserver],
      home: CompanionScreen(
        controller: c,
        voiceFactory: (callback) => _QuietVoice(callback),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return c;
}

Future<void> _choose(WidgetTester tester, {required bool cloud}) async {
  await tester.tap(find.byKey(const Key('chat-model-picker')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.text(cloud ? 'Cloud · OpenAI · gpt-6-luna' : 'Local · Gemma 4').last,
  );
  await tester.pumpAndSettle();
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(_question, text);
  await tester.tap(find.byTooltip('Send message'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('ordinary send defaults local even with frontier configured', (
    tester,
  ) async {
    final c = await _mount(tester);
    await _send(tester, 'Explain a synthetic blood pressure reading');
    expect(c.localQuestions, ['Explain a synthetic blood pressure reading']);
    expect(c.prepared, 0);
    expect(c.cloudRequests, isEmpty);
    expect(c.useFrontierForChat, false);
    expect(find.textContaining('Local chat · AI runs'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'cancelling the initial warning keeps local without sending context',
    (tester) async {
      final c = await _mount(tester);
      await tester.enterText(_question, 'SYNTHETIC QUESTION');
      await _choose(tester, cloud: true);
      expect(find.text('Cloud model privacy'), findsOneWidget);
      expect(find.textContaining('private medical details'), findsOneWidget);
      expect(find.textContaining('32 model calls'), findsOneWidget);
      expect(c.prepared, 0);
      expect(c.cloudRequests, isEmpty);
      await tester.tap(find.text('Keep local'));
      await tester.pumpAndSettle();
      expect(c.frontierDisclosureAccepted, false);
      expect(c.useFrontierForChat, false);
      expect(c.disclosureWrites, 0);
      expect(c.cloudRequests, isEmpty);
      expect(
        tester.widget<TextField>(_question).controller!.text,
        'SYNTHETIC QUESTION',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'one acknowledgment enables key-only cloud sends without repeated popups',
    (tester) async {
      final c = await _mount(tester);
      await _choose(tester, cloud: true);
      await tester.tap(find.text('Use cloud models'));
      await tester.pumpAndSettle();
      expect(c.frontierDisclosureAccepted, true);
      expect(c.remoteWrites, 0);
      expect(c.useFrontierForChat, true);
      expect(c.disclosureWrites, 1);
      expect(c.cloudRequests, isEmpty);
      expect(find.textContaining('Cloud chat · OpenAI'), findsOneWidget);
      await _send(tester, 'SYNTHETIC FIRST QUESTION');
      await _send(tester, 'SYNTHETIC SECOND QUESTION');
      expect(c.cloudRequests.map((r) => r.question), [
        'SYNTHETIC FIRST QUESTION',
        'SYNTHETIC SECOND QUESTION',
      ]);
      expect(
        c.cloudRequests.first.previewText,
        contains('SYNTHETIC OWNED HISTORY'),
      );
      expect(
        c.cloudRequests.every(
          (request) =>
              request.endpoint == 'https://api.openai.com/v1/responses',
        ),
        isTrue,
      );
      expect(
        c.cloudRequests.every((request) => request.profileId == c.profile!.id),
        isTrue,
      );
      expect(c.localQuestions, isEmpty);
      expect(find.text('Cloud model privacy'), findsNothing);
      await _choose(tester, cloud: false);
      await _send(tester, 'SYNTHETIC LOCAL AGAIN');
      expect(c.localQuestions, ['SYNTHETIC LOCAL AGAIN']);
      await _choose(tester, cloud: true);
      expect(find.text('Cloud model privacy'), findsNothing);
      expect(c.disclosureWrites, 1);
      expect(c.useFrontierForChat, true);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'a restored acknowledgment skips the warning when choosing cloud',
    (tester) async {
      final c = await _mount(tester, acknowledged: true);
      await _choose(tester, cloud: true);
      expect(c.useFrontierForChat, true);
      expect(c.disclosureWrites, 0);
      expect(find.text('Cloud model privacy'), findsNothing);
      await _send(tester, 'SYNTHETIC RESTORED QUESTION');
      expect(c.cloudRequests.single.question, 'SYNTHETIC RESTORED QUESTION');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'revoking remote AI returns sends to local without clearing the saved disclosure',
    (tester) async {
      final c = await _mount(tester, acknowledged: true);
      await _choose(tester, cloud: true);
      expect(c.useFrontierForChat, isTrue);
      await c.setAllowRemoteAi(false);
      await tester.pumpAndSettle();
      await _send(tester, 'SYNTHETIC LOCAL AFTER REVOCATION');
      expect(c.allowRemoteAi, isFalse);
      expect(c.useFrontierForChat, isFalse);
      expect(c.frontierDisclosureAccepted, isTrue);
      expect(c.frontierAvailable, isTrue);
      expect(c.localQuestions, ['SYNTHETIC LOCAL AFTER REVOCATION']);
      expect(c.cloudRequests, isEmpty);
      expect(c.prepared, 0);
      expect(c.remoteWrites, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
