import 'dart:async';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/ui/profile_home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<DemoController> _ready() async {
  final controller = DemoController();
  await controller.initialize();
  return controller;
}

Future<void> _pumpHome(
  WidgetTester tester,
  AppController controller, {
  Future<void> Function(String)? onOpenProfile,
  VoidCallback? onAddProfile,
}) => tester.pumpWidget(
  MaterialApp(
    home: ProfileHomeScreen(
      controller: controller,
      onOpenProfile: onOpenProfile ?? (_) async {},
      onAddProfile: onAddProfile ?? () {},
    ),
  ),
);

void main() {
  testWidgets('empty home offers Add profile through the caller', (
    tester,
  ) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    var addCalls = 0;
    await _pumpHome(tester, controller, onAddProfile: () => addCalls++);

    expect(find.text('Add your first profile to begin.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('home-add-profile')));
    expect(addCalls, 1);
    expect(controller.data.profiles, isEmpty);
  });

  testWidgets('home shows profile labels and forwards the tapped owner id', (
    tester,
  ) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    await controller.createProfile(
      'Test Child',
      DateTime(2020, 3, 4),
      '',
      true,
    );
    final childId = controller.activeProfileId!;
    await controller.createProfile(
      'Test Adult',
      DateTime(1989, 6, 7),
      '',
      false,
    );
    final activeId = controller.activeProfileId;
    final opened = <String>[];
    await _pumpHome(
      tester,
      controller,
      onOpenProfile: (id) async => opened.add(id),
    );

    expect(find.text('Test Child'), findsOneWidget);
    expect(find.text('Test Adult'), findsOneWidget);
    expect(find.text('Child profile · Born Mar 4, 2020'), findsOneWidget);
    expect(find.text('Adult profile · Born Jun 7, 1989'), findsOneWidget);
    await tester.tap(find.text('Test Child'));
    await tester.pump();
    expect(opened, [childId]);
    // The app callback owns selection and navigation.
    expect(controller.activeProfileId, activeId);
  });

  testWidgets('home refreshes when profiles are added or renamed', (
    tester,
  ) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    await _pumpHome(tester, controller);
    await controller.createProfile(
      'New Person',
      DateTime(2000, 2, 3),
      '',
      false,
    );
    await tester.pump();

    expect(find.text('Add your first profile to begin.'), findsNothing);
    expect(find.text('New Person'), findsOneWidget);
    await controller.updateProfile(
      controller.activeProfileId!,
      name: 'Renamed Person',
      dateOfBirth: DateTime(2000, 2, 3),
      history: '',
      isChild: false,
    );
    await tester.pump();
    expect(find.text('Renamed Person'), findsOneWidget);
    expect(find.text('New Person'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy profile does not invent a birth date', (tester) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    controller.data = const VaultData(
      profiles: [
        Profile(id: 'legacy', name: 'Legacy Person', history: '', age: 12),
      ],
    );
    await _pumpHome(tester, controller);
    expect(find.text('Legacy Person'), findsOneWidget);
    expect(find.text('Child profile'), findsOneWidget);
    expect(find.textContaining('Born'), findsNothing);
  });

  testWidgets('loading and busy states prevent profile actions', (
    tester,
  ) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    await controller.createProfile('Test Person', DateTime(2000), '', false);
    controller.loaded = false;
    var addCalls = 0;
    var openCalls = 0;
    await _pumpHome(
      tester,
      controller,
      onOpenProfile: (_) async => openCalls++,
      onAddProfile: () => addCalls++,
    );

    expect(find.text('Loading your profiles…'), findsOneWidget);
    expect(find.text('Test Person'), findsNothing);
    await tester.tap(find.byKey(const Key('home-add-profile')));
    expect(addCalls, 0);

    controller.loaded = true;
    controller.busy = true;
    controller.refreshViews();
    await tester.pump();
    await tester.tap(find.text('Test Person'));
    await tester.tap(find.byKey(const Key('home-add-profile')));
    expect(openCalls, 0);
    expect(addCalls, 0);
  });

  testWidgets('an unfinished open prevents duplicate requests', (tester) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    await controller.createProfile('Test Person', DateTime(2000), '', false);
    final gate = Completer<void>();
    var openCalls = 0;
    var addCalls = 0;
    await _pumpHome(
      tester,
      controller,
      onOpenProfile: (_) {
        openCalls++;
        return gate.future;
      },
      onAddProfile: () => addCalls++,
    );
    await tester.tap(find.text('Test Person'));
    await tester.pump();
    await tester.tap(find.text('Test Person'));
    await tester.tap(find.byKey(const Key('home-add-profile')));
    expect(openCalls, 1);
    expect(addCalls, 0);

    gate.complete();
    await tester.pump();
    await tester.tap(find.byKey(const Key('home-add-profile')));
    expect(addCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed open offers retry without exposing exception details', (
    tester,
  ) async {
    final controller = await _ready();
    addTearDown(controller.dispose);
    await controller.createProfile('Test Person', DateTime(2000), '', false);
    var openCalls = 0;
    await _pumpHome(
      tester,
      controller,
      onOpenProfile: (_) async {
        openCalls++;
        throw StateError('private-vault-runtime-detail');
      },
    );
    await tester.tap(find.text('Test Person'));
    await tester.pump();
    expect(
      find.text('Couldn’t open this profile. Please try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('private-vault-runtime-detail'), findsNothing);
    await tester.tap(find.text('Test Person'));
    await tester.pump();
    expect(openCalls, 2);
    expect(tester.takeException(), isNull);
  });
}
