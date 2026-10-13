// Per-profile file-library widget checks (MSG-087).
// Synthetic data only. DemoController stays in memory: no models, no network.

import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/ui/profile_files_screen.dart';
import 'package:ayumitra/ui/profiles_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Report _file(
  String id,
  String profileId,
  String name, {
  ReportStatus status = ReportStatus.saved,
  DateTime? eventDate,
  String extension = 'txt',
}) => Report(
  id: id,
  profileId: profileId,
  name: name,
  extension: extension,
  digest: 'digest-$id',
  importedAt: DateTime(2026, 10, 12),
  eventDate: eventDate,
  status: status,
  type: 'lab',
);

/// Two synthetic profiles; returns the controller with profile A active.
Future<DemoController> _ready() async {
  final controller = DemoController();
  await controller.initialize();
  await controller.createProfile('Test Alpha', DateTime(2020, 3, 4), '', true);
  final idA = controller.activeProfileId!;
  await controller.createProfile('Test Beta', DateTime(2019, 6, 7), '', false);
  final idB = controller.activeProfileId!;
  controller.data = controller.data.copy(
    reports: [
      _file('a1', idA, 'alpha-blood.txt', eventDate: DateTime(2026, 9, 2)),
      _file('a2', idA, 'alpha-scan.txt', status: ReportStatus.ready),
      _file('b1', idB, 'beta-notes.txt'),
    ],
  );
  await controller.selectProfile(idA);
  return controller;
}

Future<void> _pumpLibrary(
  WidgetTester tester,
  DemoController controller,
  String profileId, {
  List<Report> openedReports = const [],
  List<Report> openedOriginals = const [],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ProfileFilesScreen(
        controller: controller,
        profileId: profileId,
        onOpenReport: openedReports.add,
        onOpenOriginal: openedOriginals.add,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('library shows only the selected profile’s files', (
    tester,
  ) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    final idA = controller.activeProfileId!;
    await _pumpLibrary(tester, controller, idA);

    expect(find.text('Test Alpha’s files'), findsOneWidget);
    expect(find.text('alpha-blood.txt'), findsOneWidget);
    expect(find.text('alpha-scan.txt'), findsOneWidget);
    expect(find.text('beta-notes.txt'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty library names the owner and keeps the find field', (
    tester,
  ) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    final idB = controller.data.profiles.last.id;
    await controller.selectProfile(idB);
    controller.data = controller.data.copy(
      reports: controller.data.reports
          .where((r) => r.profileId != idB)
          .toList(),
    );
    await _pumpLibrary(tester, controller, idB);

    expect(find.textContaining('No files yet'), findsOneWidget);
    expect(find.text('Find by filename'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unprocessed and failed files stay visible with status', (
    tester,
  ) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    final idA = controller.activeProfileId!;
    controller.data = controller.data.copy(
      reports: [
        _file('u1', idA, 'pending-upload.txt'),
        _file('u2', idA, 'blurry-photo.txt', status: ReportStatus.failed),
      ],
    );
    await _pumpLibrary(tester, controller, idA);

    expect(find.text('pending-upload.txt'), findsOneWidget);
    // Status shares the subtitle Text with type/date, so match the exact
    // status string as a substring; both saved and failed stay asserted.
    expect(find.textContaining('Saved · not read yet'), findsOneWidget);
    expect(find.text('blurry-photo.txt'), findsOneWidget);
    expect(
      find.textContaining('Could not be read · original kept'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('each file shows its original format', (tester) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    final idA = controller.activeProfileId!;
    controller.data = controller.data.copy(
      reports: [
        _file('f1', idA, 'lab-print.pdf', extension: 'pdf'),
        _file('f2', idA, 'phone-photo.png', extension: 'png'),
        _file('f3', idA, 'typed-notes.txt'),
      ],
    );
    await _pumpLibrary(tester, controller, idA);

    expect(find.text('lab-print.pdf'), findsOneWidget);
    expect(find.textContaining('PDF ·'), findsOneWidget);
    expect(find.text('phone-photo.png'), findsOneWidget);
    expect(find.textContaining('PNG ·'), findsOneWidget);
    expect(find.text('typed-notes.txt'), findsOneWidget);
    expect(find.textContaining('TXT ·'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('filename find filters the list', (tester) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    final idA = controller.activeProfileId!;
    await _pumpLibrary(tester, controller, idA);

    await tester.enterText(find.byType(TextField), 'scan');
    await tester.pumpAndSettle();
    expect(find.text('alpha-scan.txt'), findsOneWidget);
    expect(find.text('alpha-blood.txt'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz-no-match');
    await tester.pumpAndSettle();
    expect(find.textContaining('No files match'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('report tap and Open original use caller callbacks', (
    tester,
  ) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    final idA = controller.activeProfileId!;
    final reports = <Report>[];
    final originals = <Report>[];
    await _pumpLibrary(
      tester,
      controller,
      idA,
      openedReports: reports,
      openedOriginals: originals,
    );

    await tester.tap(find.text('alpha-blood.txt'));
    await tester.pumpAndSettle();
    expect(reports.map((r) => r.id), ['a1']);
    // A callback records instead of navigating: the library stays put.
    expect(find.text('Test Alpha’s files'), findsOneWidget);

    await tester.tap(find.byTooltip('Open original').first);
    await tester.pumpAndSettle();
    expect(originals.map((r) => r.id), ['a1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile switch turns a stale library into a guard', (
    tester,
  ) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    final idA = controller.activeProfileId!;
    final idB = controller.data.profiles.last.id;
    await _pumpLibrary(tester, controller, idA);
    expect(find.text('alpha-blood.txt'), findsOneWidget);

    await controller.selectProfile(idB);
    await tester.pumpAndSettle();
    expect(find.textContaining('switched profiles'), findsOneWidget);
    expect(find.text('alpha-blood.txt'), findsNothing);
    expect(find.text('alpha-scan.txt'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Manage-profiles folder button selects before opening', (
    tester,
  ) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    final idB = controller.data.profiles.last.id;
    expect(controller.activeProfileId, isNot(idB));

    final seen = <Profile>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ProfilesScreen(controller: controller, onViewFiles: seen.add),
      ),
    );
    await tester.pumpAndSettle();

    // Second person’s folder button: Beta is listed after Alpha.
    await tester.tap(find.byTooltip('View files').at(1));
    await tester.pumpAndSettle();
    expect(controller.activeProfileId, idB);
    expect(seen.map((p) => p.id), [idB]);
    expect(tester.takeException(), isNull);
  });
}
