// Sidebar navigation + step-timeline widget checks (MSG-083).
// Synthetic data only. DemoController + local fakes: no models, no network.

import 'dart:async';

import 'package:ayumitra/domain/conversations.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scripted localhost stand-in. Summary answers stay gated behind
/// [summaryGate] so tests can observe the busy UI mid-flight.
class _NavIntelligence extends LocalIntelligence {
  String plannerResponse = '{"action":"conversation","query":""}';
  Completer<String>? summaryGate;
  bool summaryRequested = false;

  @override
  bool get available => true;

  @override
  Future<String> generate(String instruction, String input) async {
    if (instruction == plannerPrompt) return plannerResponse;
    if (instruction == summaryPrompt) {
      summaryRequested = true;
      final gate = summaryGate;
      if (gate != null) return gate.future;
    }
    return 'Local answer.';
  }
}

ConversationSession _session(String id, String profileId, String title) =>
    ConversationSession(
      id: id,
      profileId: profileId,
      title: title,
      createdAt: DateTime(2026, 10, 1),
      updatedAt: DateTime(2026, 10, 2),
    );

Report _report(String id, String profileId, String name) => Report(
  id: id,
  profileId: profileId,
  name: name,
  extension: 'txt',
  digest: 'digest-$id',
  importedAt: DateTime(2026, 10, 12),
  lines: const [SourceLine(id: 'l1', page: 1, text: 'hemoglobin value ok')],
  type: 'lab',
);

Future<DemoController> _ready() async {
  final controller = DemoController(intelligence: _NavIntelligence());
  await controller.initialize();
  await controller.createProfile('Test Child', DateTime(2021, 4, 18), '', true);
  return controller;
}

void main() {
  testWidgets(
    'Desktop sidebar navigates sections, files, and delete stays reachable',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = await _ready();
      addTearDown(controller.dispose);
      final profileId = controller.activeProfileId!;
      controller.data = controller.data.copy(
        sessions: [
          _session('s1', profileId, 'Alpha'),
          _session('s2', profileId, 'Beta'),
          _session('s3', profileId, 'Gamma'),
        ],
        reports: [
          _report('r1', profileId, 'blood-a.txt'),
          _report('r2', profileId, 'scan-b.txt'),
        ],
      );
      await tester.pumpWidget(AyumitraApp(controller: controller));
      await tester.pumpAndSettle();

      // Sidebar sections render on wide screens without a drawer.
      expect(find.text('CONVERSATIONS'), findsOneWidget);
      expect(find.text('FILES'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('blood-a.txt'), findsOneWidget);

      // The 1100px sidebar is a lazily-built ListView: lower tiles (Report
      // history, files, delete) mount only after scrolling within it, and the
      // newer View files tile adds height. Scope every lookup to the sidebar
      // and scroll into view before tapping, mirroring the small-viewport
      // test. Navigation targets and assertions are unchanged.
      final sidebar = find.byKey(const Key('companion-navigation'));
      final sidebarScrollable = find.descendant(
        of: sidebar,
        matching: find.byType(Scrollable),
      );
      Future<void> tapSidebarTile(Finder target) async {
        final tile = find.descendant(of: sidebar, matching: target);
        await tester.scrollUntilVisible(
          tile,
          300,
          scrollable: sidebarScrollable,
        );
        await tester.pumpAndSettle();
        await tester.tap(tile);
        await tester.pumpAndSettle();
      }

      // The drawer section controls keep navigation independent of labels.
      await tapSidebarTile(find.byKey(const Key('history-section-switch')));
      expect(find.text('Report history'), findsOneWidget);
      await tapSidebarTile(find.byKey(const Key('companion-section-switch')));
      expect(find.text('Report history'), findsNothing);

      // A FILES tile opens the report screen for this profile.
      await tapSidebarTile(find.text('scan-b.txt'));
      expect(find.text('Open original'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('CONVERSATIONS'), findsOneWidget);

      // Delete stays reachable with a confirm step; only that chat goes.
      await tapSidebarTile(
        find
            .descendant(
              of: sidebar,
              matching: find.byTooltip('Delete conversation'),
            )
            .first,
      );
      expect(find.text('Delete this conversation?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(controller.data.sessions, hasLength(2));
      expect(find.text('Delete this conversation?'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Small viewport reaches every session and file by scrolling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = await _ready();
    addTearDown(controller.dispose);
    final profileId = controller.activeProfileId!;
    controller.data = controller.data.copy(
      sessions: [
        for (var i = 1; i <= 25; i++) _session('s$i', profileId, 'Chat $i'),
      ],
      reports: [_report('r1', profileId, 'scan.txt')],
    );
    await tester.pumpWidget(AyumitraApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.text('CONVERSATIONS'), findsOneWidget);

    // The sidebar ListView lazily builds far rows, so Chat 25 is not
    // mounted until scrolled into view. Scroll within the sidebar only.
    final sidebar = find.byKey(const Key('companion-navigation'));
    final sidebarScrollable = find.descendant(
      of: sidebar,
      matching: find.byType(Scrollable),
    );
    final chat25 = find.descendant(of: sidebar, matching: find.text('Chat 25'));
    await tester.scrollUntilVisible(chat25, 300, scrollable: sidebarScrollable);
    await tester.pumpAndSettle();
    await tester.tap(chat25);
    await tester.pumpAndSettle();
    expect(controller.activeSessionId, 's25');

    // Files stay reachable too, opening the report screen.
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    final scanFile = find.descendant(
      of: sidebar,
      matching: find.text('scan.txt'),
    );
    await tester.scrollUntilVisible(
      scanFile,
      300,
      scrollable: sidebarScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(scanFile);
    await tester.pumpAndSettle();
    expect(find.text('Open original'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Processing steps show as controlled labels, never raw thought', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final intelligence = _NavIntelligence()
      ..plannerResponse =
          '{"actions":[{"action":"search_records","query":"hemoglobin"}]}';
    final gate = Completer<String>();
    intelligence.summaryGate = gate;
    final controller = DemoController(intelligence: intelligence);
    await controller.initialize();
    addTearDown(controller.dispose);
    await controller.createProfile(
      'Test Child',
      DateTime(2021, 4, 18),
      '',
      true,
    );
    controller.data = controller.data.copy(
      reports: [_report('r1', controller.activeProfileId!, 'blood.txt')],
    );
    await tester.pumpWidget(AyumitraApp(controller: controller));
    await tester.pumpAndSettle();

    final asking = controller.ask('hemoglobin?');
    for (var i = 0; i < 50 && !intelligence.summaryRequested; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(intelligence.summaryRequested, isTrue);
    // Finished tools stay listed; the running step shows beneath them.
    expect(find.text('Recalling earlier conversation…'), findsOneWidget);
    expect(find.text('Searching your saved reports…'), findsOneWidget);
    expect(find.text('Writing your answer…'), findsOneWidget);
    // Prompt internals and model chatter never render as UI text.
    expect(find.textContaining('sourceId'), findsNothing);
    expect(find.textContaining('recentUserRequests'), findsNothing);

    gate.complete('Synthetic report evidence [r1/l1].');
    await asking;
    await tester.pumpAndSettle();
    expect(find.textContaining('Synthetic report evidence'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
