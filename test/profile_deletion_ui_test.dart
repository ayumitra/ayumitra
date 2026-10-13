import 'package:ayumitra/domain/conversations.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/ui/profiles_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _DeletionController extends DemoController {
  final deletedIds = <String>[];

  @override
  Future<void> deleteProfile(String id) async {
    deletedIds.add(id);
    await super.deleteProfile(id);
  }
}

Report _report(String id, String profileId) => Report(
  id: id,
  profileId: profileId,
  name: '$id.txt',
  extension: 'txt',
  digest: 'synthetic-$id',
  importedAt: DateTime(2026, 10, 1),
);

ConversationSession _session(String profileId) => ConversationSession(
  id: 'session-$profileId',
  profileId: profileId,
  title: 'Synthetic conversation',
  createdAt: DateTime(2026, 10, 1),
  updatedAt: DateTime(2026, 10, 1),
);

Future<_DeletionController> _ready() async {
  final controller = _DeletionController();
  await controller.initialize();
  await controller.createProfile('Test Alpha', DateTime(2020, 3, 4), '', true);
  final alphaId = controller.activeProfileId!;
  await controller.createProfile('Test Beta', DateTime(1989, 6, 7), '', false);
  final betaId = controller.activeProfileId!;
  controller.data = controller.data.copy(
    reports: [
      _report('alpha-1', alphaId),
      _report('alpha-2', alphaId),
      _report('beta-1', betaId),
    ],
    sessions: [_session(alphaId), _session(betaId)],
    memories: [
      ConversationMemory(
        id: 'memory-$alphaId',
        profileId: alphaId,
        sessionId: 'session-$alphaId',
        text: 'Synthetic Alpha memory',
        updatedAt: DateTime(2026, 10, 1),
      ),
      ConversationMemory(
        id: 'memory-$betaId',
        profileId: betaId,
        sessionId: 'session-$betaId',
        text: 'Synthetic Beta memory',
        updatedAt: DateTime(2026, 10, 1),
      ),
    ],
  );
  return controller;
}

Future<void> _pump(
  WidgetTester tester,
  _DeletionController controller, {
  void Function(Profile)? onViewFiles,
}) => tester.pumpWidget(
  MaterialApp(
    home: ProfilesScreen(controller: controller, onViewFiles: onViewFiles),
  ),
);

Future<void> _action(WidgetTester tester, String id, String action) async {
  final menu = find.byKey(ValueKey('profile-actions-$id'));
  await tester.ensureVisible(menu);
  await tester.tap(menu);
  await tester.pumpAndSettle();
  await tester.tap(find.text(action));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('named deletion confirmation counts only that person’s data', (
    tester,
  ) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    final alphaId = controller.data.profiles.first.id;
    await _pump(tester, controller);
    await _action(tester, alphaId, 'Delete profile');
    expect(find.text('Delete Test Alpha’s profile?'), findsOneWidget);
    expect(find.textContaining('2 files, 1 conversation'), findsOneWidget);
    expect(find.textContaining('all remembered context'), findsOneWidget);
    await tester.tap(find.text('Keep profile'));
    await tester.pumpAndSettle();
    expect(controller.deletedIds, isEmpty);
    expect(controller.data.profiles.length, 2);
    expect(controller.data.reports.length, 3);
    expect(controller.data.memories.length, 2);
  });

  testWidgets(
    'confirmed deletion removes owner data and closes their edit form',
    (tester) async {
      final controller = await _ready();
      addTearDown(controller.dispose);
      final alphaId = controller.data.profiles.first.id;
      final betaId = controller.data.profiles.last.id;
      await _pump(tester, controller);
      await _action(tester, alphaId, 'Edit profile');
      expect(find.byType(TextField), findsWidgets);
      await _action(tester, alphaId, 'Delete profile');
      await tester.tap(find.text('Delete profile'));
      await tester.pumpAndSettle();

      expect(controller.deletedIds, [alphaId]);
      expect(find.text('Test Alpha'), findsNothing);
      expect(find.text('Test Beta'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(controller.data.profiles.map((person) => person.id), [betaId]);
      expect(controller.data.reports.map((report) => report.id), ['beta-1']);
      expect(controller.data.sessions.map((session) => session.profileId), [
        betaId,
      ]);
      expect(controller.data.memories.map((memory) => memory.profileId), [
        betaId,
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('busy state blocks actions and is rechecked after confirmation', (
    tester,
  ) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    final alphaId = controller.data.profiles.first.id;
    controller.busy = true;
    await _pump(tester, controller);
    await tester.tap(find.byKey(ValueKey('profile-actions-$alphaId')));
    await tester.pumpAndSettle();
    expect(find.text('Delete profile'), findsNothing);
    expect(find.text('Edit profile'), findsNothing);

    controller.busy = false;
    controller.refreshViews();
    await tester.pump();
    await _action(tester, alphaId, 'Delete profile');
    controller.busy = true;
    controller.refreshViews();
    await tester.tap(find.text('Delete profile'));
    await tester.pumpAndSettle();
    expect(controller.deletedIds, isEmpty);
    expect(controller.data.profiles.length, 2);
  });

  testWidgets(
    'deletion failure is visible while creation and editing are closed',
    (tester) async {
      final controller = await _ready();
      addTearDown(controller.dispose);
      controller.failure = 'Could not delete the profile. Please try again.';
      await _pump(tester, controller);
      expect(find.byType(TextField), findsNothing);
      expect(find.text(controller.failure!), findsOneWidget);
    },
  );

  testWidgets(
    'narrow cards keep files in the menu and select the correct owner',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = await _ready();
      addTearDown(controller.dispose);
      final alphaId = controller.data.profiles.first.id;
      await controller.updateProfile(
        alphaId,
        name: 'Synthetic Person With A Long Family Name',
        dateOfBirth: DateTime(2020, 3, 4),
        history: '',
        isChild: true,
      );
      final opened = <String>[];
      await _pump(
        tester,
        controller,
        onViewFiles: (profile) => opened.add(profile.id),
      );
      await _action(tester, alphaId, 'View files');
      expect(controller.activeProfileId, alphaId);
      expect(opened, [alphaId]);
      expect(tester.takeException(), isNull);
    },
  );
}
