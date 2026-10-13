import 'package:ayumitra/ui/camera_pages_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _show(
  WidgetTester tester,
  int capturedPages,
  void Function(bool) onResult,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              onResult(await askForAnotherCameraPage(context, capturedPages));
            },
            child: const Text('Show capture choices'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Show capture choices'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('another page is an explicit capture choice after one page', (
    tester,
  ) async {
    bool? result;
    await _show(tester, 1, (value) => result = value);
    expect(find.text('1 page captured'), findsOneWidget);
    expect(find.text('Process 1 page'), findsOneWidget);
    expect(find.textContaining('up to 5 pages'), findsOneWidget);
    expect(result, isNull);

    await tester.tap(find.text('Add another page'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('process choice returns false and reports the captured count', (
    tester,
  ) async {
    bool? result;
    await _show(tester, 4, (value) => result = value);
    expect(find.text('4 pages captured'), findsOneWidget);
    expect(find.text('Process 4 pages'), findsOneWidget);

    await tester.tap(find.text('Process 4 pages'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('dismissing capture choices processes the pages already taken', (
    tester,
  ) async {
    bool? result;
    await _show(tester, 2, (value) => result = value);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('five or more pages proceed immediately without another prompt', (
    tester,
  ) async {
    for (final count in [5, 6]) {
      bool? result;
      await _show(tester, count, (value) => result = value);
      expect(result, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Add another page'), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });
}
