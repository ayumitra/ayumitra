import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Onboarding asks for date of birth and history without cloud mode choices',
    (tester) async {
      final controller = AppController()..loaded = true;
      await tester.pumpWidget(AyumitraApp(controller: controller));
      expect(find.text('Date of birth'), findsOneWidget);
      expect(find.text('Previous history (optional)'), findsOneWidget);
      expect(find.textContaining('one-time privacy warning'), findsOneWidget);
      await tester.ensureVisible(find.text('Meet my companion'));
      await tester.tap(find.text('Meet my companion'));
      await tester.pump();
      expect(find.text('Enter a name.'), findsOneWidget);
      expect(
        find.text('Enter a valid date of birth, not a future date.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('History isolates profiles and labels unknown report dates', (
    tester,
  ) async {
    final controller = AppController()
      ..loaded = true
      ..activeProfileId = 'child-a';
    controller.data = VaultData(
      profiles: [
        Profile(
          id: 'child-a',
          name: 'Synthetic Child',
          age: 8,
          ageRecordedAt: DateTime(2026, 10, 12),
          history: '',
        ),
      ],
      reports: [
        Report(
          id: 'report-a',
          profileId: 'child-a',
          name: 'Visible report',
          extension: 'txt',
          digest: 'a',
          importedAt: DateTime(2026, 10, 12),
        ),
        Report(
          id: 'report-b',
          profileId: 'child-b',
          name: 'Other person’s report',
          extension: 'txt',
          digest: 'b',
          importedAt: DateTime(2026, 10, 12),
        ),
      ],
    );
    await tester.pumpWidget(AyumitraApp(controller: controller));
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('history-section-switch')));
    await tester.pumpAndSettle();
    expect(find.text('Visible report'), findsOneWidget);
    expect(find.textContaining('Report date unknown'), findsOneWidget);
    expect(find.text('Other person’s report'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
