import 'dart:async';
import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/conversations.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/domain/second_opinion.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/ui/second_opinion_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Available extends LocalIntelligence {
  @override
  bool get available => true;
}

class _DraftController extends AppController {
  _DraftController() : super(intelligence: _Available()) {
    activeProfileId = 'p1';
    activeSessionId = 's1';
    loaded = true;
    data = VaultData(
      profiles: const [
        Profile(id: 'p1', name: 'Synthetic person', history: ''),
      ],
      sessions: [
        ConversationSession(
          id: 's1',
          profileId: 'p1',
          title: 'Synthetic conversation',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          turns: const [],
        ),
      ],
    );
  }
  final response = Completer<SecondOpinionPack?>();
  int calls = 0;
  @override
  Future<SecondOpinionPack?> generateSecondOpinionDraft() {
    calls++;
    return response.future;
  }

  SecondOpinionPack result() => SecondOpinionPack(
    profileId: 'p1',
    sessionId: 's1',
    markdown: '# Local generated draft',
    reportIds: const [],
    truncated: false,
    identifierHints: const [],
  );
}

Future<void> _mount(WidgetTester tester, _DraftController c) async {
  await tester.pumpWidget(
    MaterialApp(home: SecondOpinionScreen(controller: c)),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'draft is generated once locally and remains editable for review',
    (tester) async {
      final c = _DraftController();
      addTearDown(c.dispose);
      await _mount(tester, c);
      expect(c.calls, 1);
      expect(find.textContaining('Preparing your draft'), findsOneWidget);
      c.response.complete(c.result());
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '# Local generated draft',
      );
      await tester.scrollUntilVisible(
        find.textContaining('Draft generated'),
        150,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
        maxScrolls: 30,
      );
      await tester.pump();
      expect(find.textContaining('Draft generated'), findsOneWidget);
      expect(c.calls, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('generation never overwrites edits made while it runs', (
    tester,
  ) async {
    final c = _DraftController();
    addTearDown(c.dispose);
    await _mount(tester, c);
    await tester.enterText(find.byType(TextField), 'My own edited draft');
    c.response.complete(c.result());
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'My own edited draft',
    );
    await tester.scrollUntilVisible(
      find.textContaining('Your edits were kept'),
      150,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 30,
    );
    await tester.pump();
    expect(find.textContaining('Your edits were kept'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('a profile change discards an in-flight generation', (
    tester,
  ) async {
    final c = _DraftController();
    addTearDown(c.dispose);
    await _mount(tester, c);
    final before = tester
        .widget<TextField>(find.byType(TextField))
        .controller!
        .text;
    c.activeProfileId = 'other';
    c.response.complete(c.result());
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      before,
    );
    expect(find.textContaining('Return and rebuild'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  testWidgets('disposed generation result is ignored', (tester) async {
    final c = _DraftController();
    addTearDown(c.dispose);
    await _mount(tester, c);
    await tester.pumpWidget(const SizedBox());
    c.response.complete(c.result());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
