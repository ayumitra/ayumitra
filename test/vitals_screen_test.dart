// Vitals screen checks with a fake host. Synthetic only, no models.
import 'package:ayumitra/domain/vitals.dart';
import 'package:ayumitra/ui/vitals_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeHost extends ChangeNotifier implements VitalsHost {
  _FakeHost({List<VitalEntry>? seed, this.activeDateOfBirth})
    : activeProfileId = 'p',
      _vitals = [...?seed];

  @override
  String? activeProfileId;

  @override
  DateTime? activeDateOfBirth;
  List<VitalEntry> _vitals;
  int _nextId = 0;
  int deleteCalls = 0;
  void switchProfile(String id) {
    activeProfileId = id;
    notifyListeners();
  }

  @override
  List<VitalEntry> get vitals => _vitals;

  @override
  bool busy = false;

  @override
  Future<void> recordVital(
    VitalKind kind,
    double value, {
    double? diastolic,
    String? unit,
    DateTime? measuredAt,
    String note = '',
  }) async {
    _vitals = addVital(
      _vitals,
      VitalEntry(
        id: 'added-${_nextId++}',
        profileId: activeProfileId!,
        kind: kind,
        value: value,
        secondaryValue: diastolic,
        unit: unit ?? defaultVitalUnit(kind),
        measuredAt: measuredAt ?? DateTime.now(),
        note: note,
      ),
    );
    notifyListeners();
  }

  @override
  Future<void> deleteVital(String id) async {
    deleteCalls++;
    _vitals = _vitals.where((entry) => entry.id != id).toList();
    notifyListeners();
  }
}

VitalEntry _seed({
  String id = 'v1',
  VitalKind kind = VitalKind.spo2,
  double value = 98,
  double? secondary,
  DateTime? at,
}) => VitalEntry(
  id: id,
  profileId: 'p',
  kind: kind,
  value: value,
  secondaryValue: secondary,
  unit: defaultVitalUnit(kind),
  measuredAt: at ?? DateTime.now(),
);

Future<void> _pump(WidgetTester tester, _FakeHost host) async {
  addTearDown(host.dispose);
  await tester.pumpWidget(MaterialApp(home: VitalsScreen(host: host)));
}

/// ListView deliberately builds the form/history lazily. Exercise scrolling
/// instead of enlarging the viewport or assuming offscreen children exist.
Future<void> _show(WidgetTester tester, Finder finder) async {
  final scrollable = find
      .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
      .first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pump();
  await tester.scrollUntilVisible(
    finder,
    180,
    scrollable: scrollable,
    maxScrolls: 30,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _show(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(Key(key));
  await _show(tester, finder);
  await tester.enterText(finder, value);
  await tester.pump();
}

void main() {
  testWidgets('empty profile shows no-readings state and entry form', (
    tester,
  ) async {
    await _pump(tester, _FakeHost());
    await tester.pumpAndSettle();

    expect(find.text('No oxygen saturation readings yet'), findsOneWidget);
    expect(find.byKey(const Key('vitals-chart')), findsOneWidget);
    expect(find.textContaining('user-reported and unverified'), findsOneWidget);
    await _show(tester, find.byKey(const Key('vitals-value')));
    expect(find.byKey(const Key('vitals-value')), findsOneWidget);
    await _show(tester, find.byKey(const Key('vitals-save')));
    expect(find.byKey(const Key('vitals-save')), findsOneWidget);
  });

  testWidgets('latest reading and trend render for seeded data', (
    tester,
  ) async {
    final host = _FakeHost(
      seed: [
        _seed(value: 97, at: DateTime.now().subtract(const Duration(days: 2))),
        _seed(id: 'v2', value: 99),
      ],
    );
    await _pump(tester, host);
    await tester.pumpAndSettle();

    await _show(tester, find.text('Latest 99%'));
    expect(find.text('Latest 99%'), findsOneWidget);
    expect(find.byKey(const Key('vitals-chart')), findsOneWidget);
    await _show(tester, find.text('Recorded readings (2)'));
    expect(find.text('Recorded readings (2)'), findsOneWidget);
  });

  testWidgets('day window filters chart and list', (tester) async {
    final host = _FakeHost(
      seed: [
        _seed(
          id: 'old',
          value: 96,
          at: DateTime.now().subtract(const Duration(days: 60)),
        ),
        _seed(id: 'new', value: 99),
      ],
    );
    await _pump(tester, host);
    await tester.pumpAndSettle();
    await _show(tester, find.text('Recorded readings (2)'));
    expect(find.text('Recorded readings (2)'), findsOneWidget);

    await _tap(tester, find.byKey(const Key('vitals-window-7')));
    await tester.pumpAndSettle();
    await _show(tester, find.text('Recorded readings (1)'));
    expect(find.text('Recorded readings (1)'), findsOneWidget);
    await _show(tester, find.text('Latest 99%'));
    expect(find.text('Latest 99%'), findsOneWidget);

    await _tap(tester, find.byKey(const Key('vitals-window-all')));
    await tester.pumpAndSettle();
    await _show(tester, find.text('Recorded readings (2)'));
    expect(find.text('Recorded readings (2)'), findsOneWidget);
  });

  testWidgets('saving a measurement records it under the active profile', (
    tester,
  ) async {
    final host = _FakeHost();
    await _pump(tester, host);
    await tester.pumpAndSettle();

    await _enter(tester, 'vitals-value', '98');
    await _tap(tester, find.byKey(const Key('vitals-save')));
    await tester.pumpAndSettle();

    expect(host.vitals, hasLength(1));
    expect(host.vitals.single.value, 98);
    expect(host.vitals.single.profileId, 'p');
    await _show(tester, find.text('Latest 98%'));
    expect(find.text('Latest 98%'), findsOneWidget);
  });

  testWidgets('non-numeric input shows an error and records nothing', (
    tester,
  ) async {
    final host = _FakeHost();
    await _pump(tester, host);
    await tester.pumpAndSettle();

    await _enter(tester, 'vitals-value', 'high');
    await _tap(tester, find.byKey(const Key('vitals-save')));
    await tester.pumpAndSettle();

    await _show(tester, find.text('Enter a numeric value.'));
    expect(find.text('Enter a numeric value.'), findsOneWidget);
    expect(host.vitals, isEmpty);
  });

  testWidgets('blood pressure form requires both values', (tester) async {
    final host = _FakeHost();
    await _pump(tester, host);
    await tester.pumpAndSettle();

    await _tap(tester, find.byKey(const Key('vitals-kind-bloodPressure')));
    await tester.pumpAndSettle();
    await _show(tester, find.byKey(const Key('vitals-diastolic')));
    expect(find.byKey(const Key('vitals-diastolic')), findsOneWidget);

    await _enter(tester, 'vitals-value', '120');
    await _tap(tester, find.byKey(const Key('vitals-save')));
    await tester.pumpAndSettle();
    await _show(tester, find.text('Enter diastolic as a number.'));
    expect(find.text('Enter diastolic as a number.'), findsOneWidget);
    expect(host.vitals, isEmpty);

    await _enter(tester, 'vitals-diastolic', '80');
    await _tap(tester, find.byKey(const Key('vitals-save')));
    await tester.pumpAndSettle();
    await _show(tester, find.text('Latest 120/80 mmHg'));
    expect(find.text('Latest 120/80 mmHg'), findsOneWidget);
  });

  testWidgets('delete removes a reading after confirmation', (tester) async {
    final host = _FakeHost(seed: [_seed()]);
    await _pump(tester, host);
    await tester.pumpAndSettle();
    await _show(tester, find.text('Recorded readings (1)'));
    expect(find.text('Recorded readings (1)'), findsOneWidget);

    await _tap(tester, find.byKey(const Key('vitals-delete-v1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(host.vitals, isEmpty);
    await _show(tester, find.text('No oxygen saturation readings yet'));
    expect(find.text('No oxygen saturation readings yet'), findsOneWidget);
  });
  testWidgets('switching profiles hides an unfinished form without saving it', (
    tester,
  ) async {
    final host = _FakeHost();
    await _pump(tester, host);
    await tester.pumpAndSettle();
    await _enter(tester, 'vitals-value', '98');
    host.switchProfile('other');
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Go back and reopen Key metrics'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('vitals-save')), findsNothing);
    expect(host.vitals, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'profile changes during delete confirmation never delete prior readings',
    (tester) async {
      final host = _FakeHost(seed: [_seed()]);
      await _pump(tester, host);
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const Key('vitals-delete-v1')));
      expect(find.text('Delete this reading?'), findsOneWidget);
      host.switchProfile('other');
      await tester.pump();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(host.deleteCalls, 0);
      expect(host.vitals.single.profileId, 'p');
      expect(
        find.textContaining('Go back and reopen Key metrics'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dates before the date of birth are refused with guidance', (
    tester,
  ) async {
    final host = _FakeHost(
      activeDateOfBirth: DateTime.now().add(const Duration(days: 1)),
    );
    await _pump(tester, host);
    await tester.pumpAndSettle();
    await _enter(tester, 'vitals-value', '98');
    await _tap(tester, find.byKey(const Key('vitals-save')));
    await tester.pumpAndSettle();
    await _show(tester, find.text('Date cannot be before the date of birth.'));
    expect(
      find.text('Date cannot be before the date of birth.'),
      findsOneWidget,
    );
    expect(host.vitals, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('born-today readings save on the birth day', (tester) async {
    final now = DateTime.now();
    final host = _FakeHost(
      activeDateOfBirth: DateTime(now.year, now.month, now.day),
    );
    await _pump(tester, host);
    await tester.pumpAndSettle();
    await _enter(tester, 'vitals-value', '98');
    await _tap(tester, find.byKey(const Key('vitals-save')));
    await tester.pumpAndSettle();
    expect(host.vitals, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
