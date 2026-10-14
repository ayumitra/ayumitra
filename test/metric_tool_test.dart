// record_metric tool checks: plan validation plus controller execution
// with a scripted planner. Synthetic only, no network.
import 'dart:convert';
import 'dart:io';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/agent_plan.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/domain/vitals.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

class _ScriptedPlanner extends LocalIntelligence {
  _ScriptedPlanner(this.plan);
  final String plan;
  @override
  bool get available => true;

  @override
  Future<String> generate(String instruction, String input) async {
    if (instruction == plannerPrompt) return plan;
    return 'Recorded.';
  }
}

String _metricPlan(Map<String, Object?> metric) => jsonEncode({
  'actions': [
    {'action': 'record_metric', 'query': jsonEncode(metric)},
  ],
});

Future<AppController> _ready(
  _ScriptedPlanner planner,
  Directory directory,
) async {
  final controller = AppController(intelligence: planner)
    ..loaded = true
    ..vault = EncryptedVault(
      directory: directory,
      key: await AesGcm.with256bits().newSecretKey(),
    )
    ..activeProfileId = 'alice'
    ..data = VaultData(
      profiles: [
        Profile(
          id: 'alice',
          name: 'Synthetic Alice',
          history: '',
          dateOfBirth: DateTime(2000),
        ),
      ],
    );
  addTearDown(controller.dispose);
  return controller;
}

String _today() {
  final now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}

void main() {
  test('validator accepts a well-formed metric recording', () {
    final actions = validateAgentPlan(
      _metricPlan({'kind': 'weight', 'value': 70, 'unit': 'kg'}),
    );
    expect(actions.single.tool, 'record_metric');
  });

  test('validator rejects malformed metric recordings', () {
    for (final bad in [
      '{"action":"record_metric","query":""}',
      '{"action":"record_metric","query":"not json"}',
      _metricPlan({'kind': 'stamina', 'value': 70}),
      _metricPlan({'kind': 'weight'}),
      _metricPlan({'kind': 'weight', 'value': 'seventy'}),
      '{"action":"record_metric","query":"{\\"kind\\": \\"weight\\", \\"value\\": NaN}"}',
    ]) {
      expect(() => validateAgentPlan(bad), throwsFormatException);
    }
  });

  test(
    'planner recording persists a validated reading and confirms it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ayumitra-metric-',
      );
      try {
        final planner = _ScriptedPlanner(
          _metricPlan({'kind': 'weight', 'value': 70, 'unit': 'kg'}),
        );
        final controller = await _ready(planner, directory);
        // The executor must corroborate the plan against a real user reading.
        await controller.ask('Please log my weight 70 kg');
        expect(controller.failure, isNull);
        final reading = controller.data.vitals.single;
        expect(reading.profileId, 'alice');
        expect(reading.kind, VitalKind.weight);
        expect(reading.value, 70);
        expect(reading.unit, 'kg');
        expect(reading.source, 'user');
        expect(
          controller.messages.last.text,
          contains('Recorded weight 70 kg'),
        );
        expect(controller.messages.last.text, contains(_today()));
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'equal readings in distinct turns are retained; each tool is idempotent per turn',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ayumitra-metric-',
      );
      try {
        final planner = _ScriptedPlanner(
          _metricPlan({'kind': 'pulse', 'value': 72, 'unit': 'bpm'}),
        );
        final controller = await _ready(planner, directory);
        await controller.ask('Please record my pulse 72 bpm');
        await controller.ask('Please record my pulse 72 bpm');
        expect(controller.data.vitals, hasLength(2));
        expect(controller.messages.last.text, contains('already recorded'));
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('out-of-range values fail with the reason, never stored', () async {
    final directory = await Directory.systemTemp.createTemp('ayumitra-metric-');
    try {
      final planner = _ScriptedPlanner(
        _metricPlan({'kind': 'spo2', 'value': 140, 'unit': '%'}),
      );
      final controller = await _ready(planner, directory);
      await controller.ask('Please log my oxygen saturation 140%');
      expect(controller.data.vitals, isEmpty);
      expect(controller.messages.last.text, contains('could not record'));
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
