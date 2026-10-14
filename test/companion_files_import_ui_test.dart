import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/ui/profile_files_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FileController extends DemoController {
  int imports = 0, scans = 0;
  Future<bool> Function(int)? nextPage;
  @override
  Future<void> addFileToProfile() async {
    imports++;
  }

  @override
  Future<void> addCameraReportToProfile({
    Future<bool> Function(int)? onAnotherPage,
  }) async {
    scans++;
    nextPage = onAnotherPage;
  }
}

void main() {
  testWidgets('empty file library imports and scans without chat navigation', (
    tester,
  ) async {
    final c = _FileController();
    addTearDown(c.dispose);
    await c.initialize();
    await c.createProfile('Synthetic person', DateTime(2000), '', false);
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileFilesScreen(
          controller: c,
          profileId: c.activeProfileId!,
          onOpenReport: (_) {},
          onOpenOriginal: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('No files yet'), findsOneWidget);
    final turns = c.activeSession?.turns.length;
    await tester.tap(find.text('Add files'));
    await tester.pump();
    await tester.tap(find.text('Scan pages'));
    await tester.pump();
    expect(c.imports, 1);
    expect(c.scans, 1);
    expect(c.activeSession?.turns.length, turns);
    expect(await c.nextPage!(5), false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('busy and stale file libraries cannot start imports', (
    tester,
  ) async {
    final c = _FileController();
    addTearDown(c.dispose);
    await c.initialize();
    await c.createProfile('Synthetic person', DateTime(2000), '', false);
    final owner = c.activeProfileId!;
    c.busy = true;
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileFilesScreen(
          controller: c,
          profileId: owner,
          onOpenReport: (_) {},
          onOpenOriginal: (_) {},
        ),
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Add files'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Scan pages'),
          )
          .onPressed,
      isNull,
    );
    c.busy = false;
    await c.createProfile('Other synthetic person', DateTime(1990), '', false);
    await tester.pumpAndSettle();
    expect(find.text('Add files'), findsNothing);
    expect(find.textContaining('switched profiles'), findsOneWidget);
    expect(c.imports, 0);
    expect(tester.takeException(), isNull);
  });
}
