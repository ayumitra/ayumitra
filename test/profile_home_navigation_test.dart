import 'package:ayumitra/domain/conversations.dart';
import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/ui/app.dart';
import 'package:ayumitra/ui/profile_home_screen.dart';
import 'package:ayumitra/ui/profiles_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ConversationSession _session(String profileId, String label) =>
    ConversationSession(
      id: 'session-$profileId',
      profileId: profileId,
      title: '$label conversation',
      createdAt: DateTime(2026, 10, 1),
      updatedAt: DateTime(2026, 10, 2),
      turns: [
        ConversationTurn(
          id: 'turn-$profileId',
          role: 'user',
          text: '$label private history',
          createdAt: DateTime(2026, 10, 1),
        ),
      ],
    );

Future<DemoController> _ready() async {
  final controller = DemoController();
  await controller.initialize();
  await controller.createProfile('Test Alpha', DateTime(2020, 3, 4), '', true);
  final alphaId = controller.activeProfileId!;
  await controller.createProfile('Test Beta', DateTime(1989, 6, 7), '', false);
  final betaId = controller.activeProfileId!;
  controller.data = controller.data.copy(
    sessions: [_session(alphaId, 'Alpha'), _session(betaId, 'Beta')],
    activeSessionByProfile: {
      alphaId: 'session-$alphaId',
      betaId: 'session-$betaId',
    },
  );
  await controller.selectProfile(alphaId);
  return controller;
}

Future<void> _tapLogo(WidgetTester tester) async {
  final sidebar = find.byKey(const Key('companion-navigation'));
  await tester.tap(
    find.descendant(of: sidebar, matching: find.text('Ayumitra')),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('logo home opens another profile with its own conversation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = await _ready();
    addTearDown(controller.dispose);
    final betaId = controller.data.profiles.last.id;
    await tester.pumpWidget(AyumitraApp(controller: controller));
    await tester.pumpAndSettle();
    expect(
      find.text('Alpha private history', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Beta private history', findRichText: true), findsNothing);

    await _tapLogo(tester);
    expect(find.byType(ProfileHomeScreen), findsOneWidget);
    expect(find.text('Test Alpha'), findsOneWidget);
    expect(find.text('Test Beta'), findsOneWidget);
    expect(find.text('Add profile'), findsOneWidget);
    await tester.tap(find.text('Test Beta'));
    await tester.pumpAndSettle();

    expect(find.byType(ProfileHomeScreen), findsNothing);
    expect(controller.activeProfileId, betaId);
    expect(controller.activeSessionId, 'session-$betaId');
    expect(find.text('Test Beta’s companion'), findsOneWidget);
    expect(
      find.text('Beta private history', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.text('Alpha private history', findRichText: true),
      findsNothing,
    );
    expect(controller.messages.map((message) => message.text), [
      'Beta private history',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home Add profile opens a blank form including date of birth', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = await _ready();
    addTearDown(controller.dispose);
    final originalProfileId = controller.activeProfileId;
    await tester.pumpWidget(AyumitraApp(controller: controller));
    await tester.pumpAndSettle();

    await _tapLogo(tester);
    await tester.tap(find.byKey(const Key('home-add-profile')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilesScreen), findsOneWidget);
    expect(find.text('Date of birth (YYYY-MM-DD)'), findsOneWidget);
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Save profile'), findsOneWidget);
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(fields.length, 3);
    expect(fields.every((field) => field.controller!.text.isEmpty), isTrue);
    expect(controller.activeProfileId, originalProfileId);
    expect(controller.data.profiles.length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile manager keeps creation closed by default', (
    tester,
  ) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ProfilesScreen(controller: controller)),
    );
    expect(find.text('New profile'), findsOneWidget);
    expect(find.text('Date of birth (YYYY-MM-DD)'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });
}
