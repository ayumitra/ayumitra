// Bounded answer-repair loop checks (MSG-105 follow-up task).
// Synthetic only: scripted outputs, no models, no network.

import 'dart:convert';

import 'package:ayumitra/services/validated_answer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scripted stand-in for a model generate function. Entries are either
/// reply strings or exceptions to throw; every call is recorded.
class _ScriptedGenerate {
  _ScriptedGenerate(this.script);
  final List<Object> script;
  final List<Map<String, dynamic>> inputs = [];
  int calls = 0;

  Future<String> call(String instruction, String input) async {
    inputs.add({
      'instruction': instruction,
      'payload': jsonDecode(input) as Map<String, dynamic>,
    });
    final next = script[calls++];
    if (next is Exception || next is Error) throw next;
    return next as String;
  }
}

Map<String, dynamic> _payload() => {
  'question': 'What was my hemoglobin?',
  'evidence': [
    {'sourceId': 'S1', 'value': '13'},
  ],
};

void main() {
  test('first valid answer returns immediately without repair', () async {
    final model = _ScriptedGenerate(['Value was 13 [S1].']);
    final answer = await generateValidatedAnswer(
      generate: model.call,
      instruction: 'answer',
      payload: _payload(),
      validate: (output) => output.contains('[S1]'),
    );

    expect(answer, 'Value was 13 [S1].');
    expect(model.calls, 1);
    final first = model.inputs.single['payload'] as Map<String, dynamic>;
    expect(first.containsKey('outputRepair'), false);
  });

  test('invalid first reply is repaired once, then accepted', () async {
    final model = _ScriptedGenerate([
      'Value was 13 [S1, S2] plus extra claim [MISSING].',
      'Value was 13 [S1].',
    ]);
    final statuses = <String>[];
    final answer = await generateValidatedAnswer(
      generate: model.call,
      instruction: 'answer',
      payload: _payload(),
      validate: (output) =>
          output.contains('[S1]') && !output.contains('MISSING'),
      status: statuses.add,
    );

    expect(answer, 'Value was 13 [S1].');
    expect(model.calls, 2);
    expect(statuses, ['Repair answer format (2/3)…']);
    final repair = model.inputs[1]['payload'] as Map<String, dynamic>;
    expect(repair.containsKey('outputRepair'), true);
    // The rejected reply is never echoed back into model input.
    expect(jsonEncode(model.inputs[1]), isNot(contains('MISSING')));
  });

  test('three invalid replies return null after exactly three calls', () async {
    final model = _ScriptedGenerate(['bad one', 'bad two', 'bad three']);
    final answer = await generateValidatedAnswer(
      generate: model.call,
      instruction: 'answer',
      payload: _payload(),
      validate: (_) => false,
    );

    expect(answer, isNull);
    expect(model.calls, 3);
  });

  test('rejected output never appears in any repair input', () async {
    const markerA = 'REJECTED_MARKER_ALPHA';
    const markerB = 'REJECTED_MARKER_BETA';
    final model = _ScriptedGenerate(['$markerA [X1]', '$markerB [X2]', 'fine']);
    await generateValidatedAnswer(
      generate: model.call,
      instruction: 'answer',
      payload: _payload(),
      validate: (output) => output == 'fine',
    );

    expect(model.calls, 3);
    for (final input in model.inputs) {
      final encoded = jsonEncode(input);
      expect(encoded.contains(markerA), false);
      expect(encoded.contains(markerB), false);
    }
  });

  test('the original payload is preserved unmutated', () async {
    final Map<String, dynamic> payload = {
      'question': 'What was my hemoglobin?',
      'evidence': [
        {'sourceId': 'S1', 'value': '13'},
      ],
      'nested': {
        'flags': [true, false],
      },
    };
    final before = jsonEncode(payload);
    final model = _ScriptedGenerate(['no', 'no', 'no']);
    await generateValidatedAnswer(
      generate: model.call,
      instruction: 'answer',
      payload: payload,
      validate: (_) => false,
    );

    expect(jsonEncode(payload), before);
    // The first attempt encodes the trusted payload exactly as supplied.
    expect(model.inputs.first['payload'], jsonDecode(before));
  });

  test('generation errors propagate without retry', () async {
    final model = _ScriptedGenerate([StateError('network down')]);
    await expectLater(
      generateValidatedAnswer(
        generate: model.call,
        instruction: 'answer',
        payload: _payload(),
        validate: (_) => true,
      ),
      throwsStateError,
    );
    expect(model.calls, 1);
  });
}
