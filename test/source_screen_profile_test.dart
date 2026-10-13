// Stale original-view profile guard (MSG-096).
// Synthetic TXT only. In-memory controller with a gated fake original store:
// no models, no network, no vault plugins.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/ui/source_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _guardText = 'not available in the active profile';

/// Ownership-blind original store: resolves whatever is planted, even after
/// a profile switch. Read-time vault checks live in the production
/// controllers; this fake isolates the UI guard — without it, planted bytes
/// would render for the wrong profile.
class _OriginalsController extends DemoController {
  Completer<Uint8List>? gate;
  final texts = <String, String>{};
  int originalCalls = 0;

  @override
  Future<Uint8List> original(Report report) async {
    originalCalls++;
    final pending = gate;
    if (pending != null) await pending.future;
    final text = texts[report.id];
    if (text == null) throw StateError('no planted original');
    return Uint8List.fromList(utf8.encode(text));
  }
}

Report _txt(String id, String profileId, String name) => Report(
  id: id,
  profileId: profileId,
  name: name,
  extension: 'txt',
  digest: 'digest-$id',
  importedAt: DateTime(2026, 10, 12),
  type: 'lab',
);

const _quote = SourceLine(id: 'l1', page: 1, text: 'hemoglobin line');

Future<_OriginalsController> _ready() async {
  final controller = _OriginalsController();
  await controller.initialize();
  await controller.createProfile('Owner Alpha', DateTime(2020, 3, 4), '', true);
  final idA = controller.activeProfileId!;
  await controller.createProfile('Owner Beta', DateTime(2019, 6, 7), '', false);
  controller.data = controller.data.copy(
    reports: [_txt('a1', idA, 'alpha-note.txt')],
  );
  await controller.selectProfile(idA);
  return controller;
}

void main() {
  testWidgets(
    'owner original hides on profile switch and returns on switch back',
    (tester) async {
      final controller = await _ready();
      addTearDown(controller.dispose);
      final idB = controller.data.profiles.last.id;
      final report = controller.data.reports.first;
      controller.texts['a1'] =
          'prefix synthetic alpha hemoglobin line one suffix';
      await tester.pumpWidget(
        MaterialApp(
          home: SourceScreen(
            controller: controller,
            report: report,
            line: _quote,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Valid owner view: document text plus the quoted line below it.
      expect(find.textContaining('synthetic alpha'), findsOneWidget);
      expect(find.text('hemoglobin line'), findsOneWidget);
      expect(controller.originalCalls, 1);

      // Switch away: cached bytes and the page quote both disappear behind
      // the generic guard, with no re-fetch of the original.
      await controller.selectProfile(idB);
      await tester.pumpAndSettle();
      expect(find.textContaining('synthetic alpha'), findsNothing);
      expect(find.text('hemoglobin line'), findsNothing);
      expect(find.textContaining(_guardText), findsOneWidget);
      expect(controller.originalCalls, 1);

      // Switch back to the same owner: the cached original shows again,
      // still without re-fetching.
      await controller.selectProfile(report.profileId);
      await tester.pumpAndSettle();
      expect(find.textContaining('synthetic alpha'), findsOneWidget);
      expect(find.text('hemoglobin line'), findsOneWidget);
      expect(controller.originalCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pending original resolving after switch is never exposed', (
    tester,
  ) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    final idB = controller.data.profiles.last.id;
    final report = controller.data.reports.first;
    controller.gate = Completer<Uint8List>();
    controller.texts['a1'] = 'synthetic alpha late bytes';
    await tester.pumpWidget(
      MaterialApp(
        home: SourceScreen(controller: controller, report: report),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Switch while the read is still pending: the guard takes over.
    await controller.selectProfile(idB);
    await tester.pump();
    expect(find.textContaining(_guardText), findsOneWidget);

    // The read now resolves successfully, but nothing is exposed.
    controller.gate!.complete(Uint8List.fromList(utf8.encode('late')));
    await tester.pumpAndSettle();
    expect(find.textContaining('synthetic alpha late'), findsNothing);
    expect(find.textContaining(_guardText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown report id shows the guard without content', (
    tester,
  ) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    final idA = controller.activeProfileId!;
    // Same owner, but no such report is stored: guard, not error text,
    // and the filename never appears anywhere on the screen.
    final ghost = _txt('ghost', idA, 'ghost-note.txt');
    await tester.pumpWidget(
      MaterialApp(
        home: SourceScreen(controller: controller, report: ghost),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining(_guardText), findsOneWidget);
    expect(find.text('ghost-note.txt'), findsNothing);
    expect(
      find.text('The original could not be opened locally.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
