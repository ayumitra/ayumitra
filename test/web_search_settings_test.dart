import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/ui/web_search_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Synthetic in-memory stand-in: real availability flag and busy/failure
/// plumbing, scripted persistence, never any real credential or storage.
class FakeSearchController extends AppController {
  int saves = 0;
  bool failNextWrite = false;

  @override
  Future<void> setWebKey(String value) async {
    saves++;
    final text = value.trim();
    if (text.isEmpty) return;
    busy = true;
    failure = null;
    notifyListeners();
    await Future<void>.delayed(Duration.zero);
    if (failNextWrite) {
      failNextWrite = false;
      failure = 'Synthetic write failure.';
    } else {
      webSearch.apiKey = text;
    }
    busy = false;
    notifyListeners();
  }
}

Finder _field() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      widget.decoration?.labelText == 'Brave Search API key',
);

String _fieldText(WidgetTester tester) =>
    tester.widget<TextField>(_field()).controller!.text;

Future<void> _pump(WidgetTester tester, FakeSearchController controller) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: WebSearchSettings(controller: controller)),
    ),
  );
}

void main() {
  testWidgets('Blank input shows unsaved status and disabled Save', (
    tester,
  ) async {
    final controller = FakeSearchController();
    await _pump(tester, controller);
    expect(find.text('No search key saved yet'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Save search key'),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(_field(), '   ');
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Save search key'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Save search key'), warnIfMissed: false);
    await tester.pump();
    expect(controller.saves, 0);
    controller.dispose();
  });

  testWidgets('Successful save clears the field and confirms', (tester) async {
    final controller = FakeSearchController();
    await _pump(tester, controller);
    await tester.enterText(_field(), 'synthetic-key');
    await tester.pump();
    await tester.tap(find.text('Save search key'));
    await tester.pumpAndSettle();
    expect(controller.saves, 1);
    expect(_fieldText(tester), isEmpty);
    expect(find.text('Search key saved on this device.'), findsOneWidget);
    expect(find.text('Search key saved on this device'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('Write failure keeps typed input with no false success', (
    tester,
  ) async {
    final controller = FakeSearchController()..failNextWrite = true;
    await _pump(tester, controller);
    await tester.enterText(_field(), 'synthetic-key');
    await tester.pump();
    await tester.tap(find.text('Save search key'));
    await tester.pumpAndSettle();
    expect(controller.saves, 1);
    expect(_fieldText(tester), 'synthetic-key');
    expect(find.text('Search key saved on this device.'), findsNothing);
    expect(find.text('Synthetic write failure.'), findsOneWidget);
    expect(controller.webSearch.available, isFalse);
    controller.dispose();
  });

  testWidgets('Reopened route labels an already saved key', (tester) async {
    final controller = FakeSearchController()..webSearch.apiKey = 'synthetic';
    controller.notifyListeners();
    await _pump(tester, controller);
    expect(find.text('Search key saved on this device'), findsOneWidget);
    expect(_fieldText(tester), isEmpty);
    expect(
      find.text('Saved. Type a replacement to change it.'),
      findsOneWidget,
    );
    controller.dispose();
  });
  testWidgets('saved-key status fits a narrow phone screen', (tester) async {
    tester.view.physicalSize = const Size(300, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = FakeSearchController()..webSearch.apiKey = 'synthetic';
    addTearDown(controller.dispose);
    await _pump(tester, controller);
    expect(find.text('Search key saved on this device'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
