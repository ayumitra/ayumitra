import 'dart:async';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/conversations.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/ui/second_opinion_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ExportController extends AppController {
  ExportController() {
    loaded = true;
    activeProfileId = 'p1';
    activeSessionId = 's1';
    data = VaultData(
      profiles: const [Profile(id: 'p1', name: 'Synthetic Child', history: '')],
      sessions: [
        ConversationSession(
          id: 's1',
          profileId: 'p1',
          title: 'Synthetic question',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          turns: [
            ConversationTurn(
              id: 't1',
              role: 'user',
              text: 'SYNTHETIC USER QUESTION',
              createdAt: DateTime(2026),
            ),
          ],
        ),
      ],
    );
  }
  final targets = <String>[];
  bool failAudit = false;

  @override
  Future<SecondOpinionAudit> recordSecondOpinionExport({
    required String target,
    required List<String> reportIds,
    required String profileId,
    required String sessionId,
  }) async {
    if (failAudit) {
      throw StateError('Synthetic storage failure');
    }
    if (profileId != activeProfileId || sessionId != activeSessionId) {
      throw StateError('Synthetic scope changed');
    }
    targets.add(target);
    return SecondOpinionAudit(
      id: 'e-${targets.length}',
      profileId: profileId,
      sessionId: sessionId,
      target: target,
      reportIds: reportIds,
      reviewed: true,
      createdAt: DateTime(2026),
    );
  }
}

Future<void> mountExport(
  WidgetTester tester,
  ExportController controller, {
  required Future<void> Function(String) copyText,
  Future<bool> Function(Uri)? openProvider,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SecondOpinionScreen(
        controller: controller,
        copyText: copyText,
        openProvider: openProvider,
      ),
    ),
  );
}

Future<void> makeVisible(WidgetTester tester, Finder target) async {
  // The outer ListView lazily mounts the controls after the large text editor.
  // Use its Scrollable, not the editor's own internal scrolling viewport.
  final outer = find
      .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
      .first;
  tester.state<ScrollableState>(outer).position.jumpTo(0);
  await tester.pump();
  await tester.scrollUntilVisible(
    target,
    200,
    scrollable: outer,
    maxScrolls: 30,
  );
  await tester.ensureVisible(target);
  await tester.pump();
}

Future<void> review(WidgetTester tester) async {
  await makeVisible(tester, find.byType(CheckboxListTile));
  await tester.tap(find.byType(CheckboxListTile));
  await tester.pump();
}

Future<void> press(WidgetTester tester, String label) async {
  await makeVisible(tester, find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  late ExportController controller;
  setUp(() => controller = ExportController());
  tearDown(() => controller.dispose());

  testWidgets(
    'Copy requires explicit review and records only a completed copy',
    (tester) async {
      final copied = <String>[];
      await mountExport(
        tester,
        controller,
        copyText: (text) async => copied.add(text),
      );
      await press(tester, 'Copy draft');
      expect(copied, isEmpty);
      expect(controller.targets, isEmpty);
      expect(find.textContaining('confirm your choice'), findsOneWidget);
      await review(tester);
      await press(tester, 'Copy draft');
      expect(copied.single, contains('SYNTHETIC USER QUESTION'));
      expect(controller.targets, ['copy']);
      expect(find.textContaining('No message was sent.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Editing resets review and updates identifier hints', (
    tester,
  ) async {
    final copied = <String>[];
    await mountExport(
      tester,
      controller,
      copyText: (text) async => copied.add(text),
    );
    await review(tester);
    await tester.enterText(
      find.byType(TextField),
      'SYNTHETIC edited zephyr@example.com',
    );
    await tester.pump();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isFalse,
    );
    expect(find.textContaining('email address'), findsOneWidget);
    await press(tester, 'Copy draft');
    expect(copied, isEmpty);
    expect(controller.targets, isEmpty);
  });

  testWidgets(
    'A changed profile or session blocks clipboard and homepage actions',
    (tester) async {
      final copied = <String>[];
      final opened = <Uri>[];
      await mountExport(
        tester,
        controller,
        copyText: (text) async => copied.add(text),
        openProvider: (uri) async {
          opened.add(uri);
          return true;
        },
      );
      await review(tester);
      controller.activeProfileId = 'other';
      await press(tester, 'Open ChatGPT');
      expect(copied, isEmpty);
      expect(opened, isEmpty);
      expect(controller.targets, isEmpty);
      expect(find.textContaining('Return and rebuild'), findsOneWidget);
    },
  );

  testWidgets('A rejected clipboard operation has no audit or browser open', (
    tester,
  ) async {
    final opened = <Uri>[];
    await mountExport(
      tester,
      controller,
      copyText: (_) async => throw StateError('Synthetic clipboard rejection'),
      openProvider: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    await review(tester);
    await press(tester, 'Open Claude');
    expect(controller.targets, isEmpty);
    expect(opened, isEmpty);
    expect(
      find.textContaining('Could not copy to the clipboard'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'A failed homepage open records the copy without claiming a provider export',
    (tester) async {
      final opened = <Uri>[];
      await mountExport(
        tester,
        controller,
        copyText: (_) async {},
        openProvider: (uri) async {
          opened.add(uri);
          return false;
        },
      );
      await review(tester);
      await press(tester, 'Open ChatGPT');
      expect(opened.single, Uri.parse('https://chatgpt.com/'));
      expect(opened.single.query, isEmpty);
      expect(controller.targets, ['copy']);
      expect(find.textContaining('browser could not open'), findsOneWidget);
      expect(find.textContaining('Provider homepage opened;'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Successful open uses only the fixed homepage and records distinct actions',
    (tester) async {
      final opened = <Uri>[];
      await mountExport(
        tester,
        controller,
        copyText: (_) async {},
        openProvider: (uri) async {
          opened.add(uri);
          return true;
        },
      );
      await review(tester);
      await press(tester, 'Open Claude');
      expect(opened.single, Uri.parse('https://claude.ai/'));
      expect(opened.single.query, isEmpty);
      expect(controller.targets, ['copy', 'claude']);
      expect(
        find.textContaining('No message was sent by Ayumitra'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Audit failure after copying is honest and does not open a provider',
    (tester) async {
      var copies = 0;
      var opens = 0;
      controller.failAudit = true;
      await mountExport(
        tester,
        controller,
        copyText: (_) async {
          copies++;
        },
        openProvider: (_) async {
          opens++;
          return true;
        },
      );
      await review(tester);
      await press(tester, 'Open ChatGPT');
      expect(copies, 1);
      expect(opens, 0);
      expect(controller.targets, isEmpty);
      expect(
        find.textContaining('local copy record could not be confirmed'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Pending copy disables repeated actions until completion', (
    tester,
  ) async {
    final completed = Completer<void>();
    var copies = 0;
    await mountExport(
      tester,
      controller,
      copyText: (_) {
        copies++;
        return completed.future;
      },
    );
    await review(tester);
    await makeVisible(tester, find.text('Copy draft'));
    await tester.tap(find.text('Copy draft'));
    await tester.pump();
    expect(copies, 1);
    expect(controller.targets, isEmpty);
    expect(
      tester
          .widget<FilledButton>(
            find.byWidgetPredicate((w) => w is FilledButton),
          )
          .onPressed,
      isNull,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    for (final button in tester.widgetList<OutlinedButton>(
      find.byWidgetPredicate((w) => w is OutlinedButton),
    )) {
      expect(button.onPressed, isNull);
    }
    completed.complete();
    await tester.pumpAndSettle();
    expect(controller.targets, ['copy']);
    expect(
      tester
          .widget<FilledButton>(
            find.byWidgetPredicate((w) => w is FilledButton),
          )
          .onPressed,
      isNotNull,
    );
  });
}
