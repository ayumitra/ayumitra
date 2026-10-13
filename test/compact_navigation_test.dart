import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Report _report(String id, String profileId, String name) => Report(
  id: id,
  profileId: profileId,
  name: name,
  extension: 'txt',
  digest: 'synthetic-$id',
  importedAt: DateTime(2026, 10, 1),
);

Future<DemoController> _mount(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = DemoController();
  await controller.initialize();
  await controller.createProfile('Synthetic Person', DateTime(2000), '', false);
  controller.data = controller.data.copy(
    reports: [
      _report('own', controller.activeProfileId!, 'Own report'),
      _report('other', 'other-person', 'Other person’s report'),
    ],
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(AyumitraApp(controller: controller));
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _openDrawer(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Open navigation menu'));
  await tester.pumpAndSettle();
}

void _expectCompactControls(WidgetTester tester) {
  final sidebar = find.byKey(const Key('companion-navigation'));
  expect(
    find.descendant(of: sidebar, matching: find.byTooltip('Companion')),
    findsOneWidget,
  );
  expect(
    find.descendant(of: sidebar, matching: find.byTooltip('History')),
    findsOneWidget,
  );
  expect(find.byType(NavigationBar), findsNothing);
  expect(find.byType(NavigationDestination), findsNothing);
  expect(
    find.descendant(of: sidebar, matching: find.text('Report history')),
    findsNothing,
  );
}

void main() {
  testWidgets(
    '390px drawer uses compact icons and closes after section choices',
    (tester) async {
      await _mount(tester, 390);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      await _openDrawer(tester);
      _expectCompactControls(tester);

      await tester.tap(find.byKey(const Key('history-section-switch')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('companion-navigation')), findsNothing);
      expect(find.text('Report history'), findsOneWidget);
      expect(find.text('Own report'), findsOneWidget);
      expect(find.text('Other person’s report'), findsNothing);
      expect(find.byType(TextField), findsNothing);

      await _openDrawer(tester);
      final history = tester.widget<IconButton>(
        find.byKey(const Key('history-section-switch')),
      );
      final colors = Theme.of(
        tester.element(find.byKey(const Key('history-section-switch'))),
      ).colorScheme;
      expect(history.color, colors.primary);
      await tester.tap(find.byKey(const Key('companion-section-switch')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('companion-navigation')), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Report history'), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop sidebar icons select history explicitly and return to chat',
    (tester) async {
      await _mount(tester, 1100);
      _expectCompactControls(tester);
      await tester.tap(find.byTooltip('History'));
      await tester.pumpAndSettle();
      expect(find.text('Report history'), findsOneWidget);
      expect(find.textContaining('Report date unknown'), findsOneWidget);
      expect(find.text('Other person’s report'), findsNothing);
      expect(find.byType(TextField), findsNothing);

      // History is an explicit section choice, so another tap stays in history.
      await tester.tap(find.byTooltip('History'));
      await tester.pumpAndSettle();
      expect(find.text('Report history'), findsOneWidget);
      await tester.tap(find.byTooltip('Companion'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Report history'), findsNothing);
      _expectCompactControls(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'busy disables both compact section controls and preserves section',
    (tester) async {
      final controller = await _mount(tester, 1100);
      await tester.tap(find.byTooltip('History'));
      await tester.pumpAndSettle();
      controller.busy = true;
      controller.refreshViews();
      await tester.pump();
      for (final key in [
        'companion-section-switch',
        'history-section-switch',
      ]) {
        expect(
          tester.widget<IconButton>(find.byKey(Key(key))).onPressed,
          isNull,
        );
        await tester.tap(find.byKey(Key(key)));
      }
      await tester.pump();
      expect(find.text('Report history'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);

      controller.busy = false;
      controller.refreshViews();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Companion'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
