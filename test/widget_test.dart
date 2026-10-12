import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/ui/app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Onboarding asks for age and history without cloud mode choices',
    (tester) async {
      final controller = AppController()..loaded = true;
      await tester.pumpWidget(AyumitraApp(controller: controller));
      expect(find.text('Age in years'), findsOneWidget);
      expect(find.text('Previous history (optional)'), findsOneWidget);
      expect(find.textContaining('never uploads your reports'), findsOneWidget);
      await tester.ensureVisible(find.text('Start my history'));
      await tester.tap(find.text('Start my history'));
      await tester.pump();
      expect(find.text('Enter a name.'), findsOneWidget);
      expect(find.text('Enter an age from 0 to 125.'), findsOneWidget);
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
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.text('Visible report'), findsOneWidget);
    expect(find.textContaining('Report date unknown'), findsOneWidget);
    expect(find.text('Other person’s report'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
