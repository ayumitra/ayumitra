// Synthetic measurement ownership/date regressions. No model, speech, web or
// provider connections: native mode uses a temporary authenticated local vault.
import 'dart:convert';
import 'dart:io';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/measurement_dates.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/domain/vitals.dart';
import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/services/local_embeddings.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

class _Call {
  _Call(this.instruction, this.payload);
  final String instruction;
  final Map<String, dynamic> payload;
}

class _ScriptedAssistant extends LocalIntelligence {
  bool enabled = false;
  double? proposedWeight;
  int plannerCalls = 0;
  final calls = <_Call>[];
  @override
  bool get available => enabled;
  @override
  Future<String> generate(String instruction, String input) async {
    if (!enabled) throw StateError('No model is needed for this operation.');
    calls.add(
      _Call(instruction, Map<String, dynamic>.from(jsonDecode(input) as Map)),
    );
    if (instruction.startsWith(plannerPrompt)) {
      plannerCalls++;
      return jsonEncode({
        'actions': [
          {
            'action': 'record_metric',
            'query': jsonEncode({
              'kind': 'weight',
              'value': proposedWeight ?? 70,
              'unit': 'kg',
            }),
          },
        ],
      });
    }
    return 'I can help you track your measurements. Personal values must come from your records or statements.';
  }
}

class _NoVectors extends LocalEmbeddings {
  @override
  bool get available => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('measurement dates require real strict calendar dates', () {
    expect(parseMeasurementDay('2024-02-29'), DateTime(2024, 2, 29));
    expect(parseMeasurementDay('2026-02-28'), DateTime(2026, 2, 28));
    for (final value in [
      '2026-02-30',
      '2025-02-29',
      '2026-04-31',
      '2026-13-01',
      '2026-00-01',
      '2026-01-00',
      '0000-01-01',
      '2026-2-01',
      '2026-02-01T00:00:00Z',
    ]) {
      expect(
        () => parseMeasurementDay(value),
        throwsA(isA<FormatException>()),
        reason: value,
      );
    }
  });

  for (final preview in [false, true]) {
    group(
      preview
          ? 'browser measurement integrity'
          : 'native measurement integrity',
      () {
        late AppController c;
        late _ScriptedAssistant model;
        Directory? directory;
        final birth = DateTime(2000, 1, 1);
        setUp(() async {
          model = _ScriptedAssistant();
          c = preview
              ? DemoController(intelligence: model, embeddings: _NoVectors())
              : AppController(intelligence: model, embeddings: _NoVectors());
          if (!preview) {
            directory = await Directory.systemTemp.createTemp(
              'ayumitra-measurement-integrity-',
            );
            c.vault = EncryptedVault(
              directory: directory!,
              key: await AesGcm.with256bits().newSecretKey(),
            );
          }
          c
            ..loaded = true
            ..activeProfileId = 'alice'
            ..data = VaultData(
              activeProfileId: 'alice',
              profiles: [
                Profile(
                  id: 'alice',
                  name: 'Synthetic Alice',
                  history: '',
                  dateOfBirth: birth,
                ),
                Profile(
                  id: 'bob',
                  name: 'Synthetic Bob',
                  history: '',
                  dateOfBirth: DateTime(2001),
                ),
              ],
            );
        });
        tearDown(() async {
          c.dispose();
          if (directory != null) {
            await directory!.delete(recursive: true);
            directory = null;
          }
        });

        test(
          'manual readings reject pre-DOB and future timestamps without writes',
          () async {
            await expectLater(
              c.recordVital(
                VitalKind.weight,
                3.125,
                measuredAt: DateTime(1999, 12, 31, 23),
              ),
              throwsA(isA<FormatException>()),
            );
            await expectLater(
              c.recordVital(
                VitalKind.height,
                50.125,
                measuredAt: DateTime.now().add(const Duration(days: 1)),
              ),
              throwsA(isA<FormatException>()),
            );
            expect(c.data.vitals, isEmpty);
            expect(c.busy, false);
          },
        );
        test(
          'birth-day weight and height preserve three decimal places and units',
          () async {
            final when = DateTime(2000, 1, 1, 8, 30);
            await c.recordVital(VitalKind.weight, 3.125, measuredAt: when);
            await c.recordVital(VitalKind.height, 50.125, measuredAt: when);
            expect(c.failure, isNull);
            expect(c.vitals, hasLength(2));
            final weight = c.vitals.singleWhere(
              (v) => v.kind == VitalKind.weight,
            );
            final height = c.vitals.singleWhere(
              (v) => v.kind == VitalKind.height,
            );
            expect(weight.value, 3.125);
            expect(weight.unit, 'kg');
            expect(height.value, 50.125);
            expect(height.unit, 'cm');
            expect(weight.measuredAt, when);
            expect(height.measuredAt, when);
            if (!preview) {
              expect(
                (await c.vault.read()).vitals.map((v) => v.value),
                containsAll([3.125, 50.125]),
              );
            }
          },
        );
        test(
          'a pre-DOB chat reading keeps the original user turn without a measurement',
          () async {
            const statement = 'My weight was 3.125 kg on December 31, 1999';
            await c.ask(statement);
            final user = c.activeSession!.turns.singleWhere(
              (turn) => turn.role == 'user',
            );
            expect(user.text, statement);
            expect(c.vitals, isEmpty);
            expect(model.calls, isEmpty);
            if (!preview) {
              final restored = await c.vault.read();
              expect(restored.vitals, isEmpty);
              expect(
                restored.sessions.single.turns
                    .singleWhere((turn) => turn.role == 'user')
                    .text,
                statement,
              );
            }
          },
        );
        test(
          'a conflicting DOB edit fails clearly and preserves DOB and readings',
          () async {
            final when = DateTime(2024, 3, 14, 9);
            await c.recordVital(VitalKind.weight, 70.125, measuredAt: when);
            final before = c.data.vitals.map((v) => v.toJson()).toList();
            await c.updateProfile(
              'alice',
              name: 'Synthetic Alice',
              dateOfBirth: DateTime(2025, 1, 1),
              history: '',
              isChild: false,
            );
            expect(c.failure, contains('Date of birth was not changed'));
            expect(c.failure, contains('before the date of birth'));
            expect(c.profile!.dateOfBirth, birth);
            expect(c.data.vitals.map((v) => v.toJson()).toList(), before);
            if (!preview) {
              final restored = await c.vault.read();
              expect(
                restored.profiles
                    .singleWhere((p) => p.id == 'alice')
                    .dateOfBirth,
                birth,
              );
              expect(restored.vitals.map((v) => v.toJson()).toList(), before);
            }
          },
        );
        test(
          'every contextual generation role receives fresh owned DOB age and dated measurements',
          () async {
            model.enabled = true;
            final now = DateTime.now();
            final weightAt = now.subtract(const Duration(days: 1));
            final heightAt = now.subtract(const Duration(days: 2));
            c.data = c.data.copy(
              vitals: [
                VitalEntry(
                  id: 'alice-weight',
                  profileId: 'alice',
                  kind: VitalKind.weight,
                  value: 70.125,
                  unit: 'kg',
                  measuredAt: weightAt,
                ),
                VitalEntry(
                  id: 'alice-height',
                  profileId: 'alice',
                  kind: VitalKind.height,
                  value: 170.456,
                  unit: 'cm',
                  measuredAt: heightAt,
                ),
                VitalEntry(
                  id: 'bob-weight',
                  profileId: 'bob',
                  kind: VitalKind.weight,
                  value: 999,
                  unit: 'kg',
                  measuredAt: now,
                ),
                VitalEntry(
                  id: 'bob-height',
                  profileId: 'bob',
                  kind: VitalKind.height,
                  value: 299,
                  unit: 'cm',
                  measuredAt: now,
                ),
              ],
            );
            final contextual = c.contextualIntelligence(
              model,
              c.profile!,
              requireActiveProfile: true,
            );
            const roles = [
              'tool-plan-role',
              'answer-role',
              'report-extraction-role',
              'health-report-role',
              'second-opinion-role',
              'research-assessment-role',
              'public-query-rewrite-role',
            ];
            for (final role in roles) {
              await contextual.generate(
                role,
                jsonEncode({
                  'profileContext': {
                    'dateOfBirth': '1900-01-01',
                    'currentWeight': {'value': 999},
                  },
                  'dateOfBirth': '1900-01-01',
                  'currentWeight': {'value': 999},
                }),
              );
            }
            expect(model.calls, hasLength(roles.length));
            for (final call in model.calls) {
              final context = call.payload['profileContext'] as Map;
              expect(
                context['dateOfBirth'],
                '2000-01-01',
                reason: call.instruction,
              );
              expect(context['ageLabel'], 'Age ${now.year - 2000}');
              expect(context['exactAge'], {
                'years': now.year - 2000,
                'months': now.month - 1,
                'days': now.day - 1,
              });
              expect(context['currentDateTime'], isA<String>());
              expect(context['currentWeight'], {
                'value': 70.125,
                'unit': 'kg',
                'measuredAt': weightAt.toIso8601String(),
                'source': 'user',
                'sourceId': 'vitals',
              });
              expect(context['currentHeight'], {
                'value': 170.456,
                'unit': 'cm',
                'measuredAt': heightAt.toIso8601String(),
                'source': 'user',
                'sourceId': 'vitals',
              });
              expect(call.payload['dateOfBirth'], '2000-01-01');
              expect(call.payload['currentWeight'], context['currentWeight']);
              expect(call.payload['currentHeight'], context['currentHeight']);
              expect(context.containsKey('profileId'), false);
            }
            // Context is rebuilt for every call, not captured at wrapper creation.
            c.data = c.data.copy(
              vitals: [
                ...c.data.vitals,
                VitalEntry(
                  id: 'alice-new-weight',
                  profileId: 'alice',
                  kind: VitalKind.weight,
                  value: 71.234,
                  unit: 'kg',
                  measuredAt: DateTime.now(),
                ),
              ],
            );
            await contextual.generate('later-answer-role', '{}');
            expect(
              ((model.calls.last.payload['profileContext']
                      as Map)['currentWeight']
                  as Map)['value'],
              71.234,
            );
          },
        );
        test(
          'an invented planner measurement cannot turn a question into a reading',
          () async {
            model
              ..enabled = true
              ..proposedWeight = 70;
            await c.ask('How do I track my weight?');
            expect(model.plannerCalls, greaterThan(0));
            expect(c.data.vitals, isEmpty);
            expect(
              c.activeSession!.turns.where((t) => t.role == 'user').single.text,
              'How do I track my weight?',
            );
            if (!preview) expect((await c.vault.read()).vitals, isEmpty);
          },
        );
        test(
          'a planner value cannot replace a different original user measurement',
          () async {
            model
              ..enabled = true
              ..proposedWeight = 80;
            await c.ask('My weight is 70 kg.');
            expect(model.plannerCalls, greaterThan(0));
            expect(c.vitals, hasLength(1));
            expect(c.vitals.single.value, 70);
            expect(c.vitals.single.unit, 'kg');
            expect(c.data.vitals.any((v) => v.value == 80), false);
            final user = c.activeSession!.turns.singleWhere(
              (t) => t.role == 'user',
            );
            expect(user.text, 'My weight is 70 kg.');
            expect(c.vitals.single.id, 'chat:${user.id}:weight');
          },
        );
      },
    );
  }
}
