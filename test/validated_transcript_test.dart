import 'package:ayumitra/services/validated_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

class _ScriptedTranscript {
  _ScriptedTranscript(this.replies);
  final List<Object> replies;
  final hints = <String>[];

  Future<String> generate(String hint) async {
    final reply = replies[hints.length];
    hints.add(hint);
    if (reply is Exception || reply is Error) throw reply;
    return reply as String;
  }
}

void main() {
  const markdown =
      '# Synthetic report\n\n| Test | Value | Unit |\n'
      '| --- | --- | --- |\n| Hb | 11.2 | g/dL |\n  - Indented text  \n'
      '[unreadable]';
  const expected = [
    '# Synthetic report',
    '| Test | Value | Unit |',
    '| --- | --- | --- |',
    '| Hb | 11.2 | g/dL |',
    '  - Indented text  ',
    '[unreadable]',
  ];

  for (final fence in <String, String>{
    'plain Markdown': '',
    'markdown fence': '```markdown\n',
    'uppercase Markdown fence': '```MARKDOWN\n',
    'short md fence': '```md\n',
    'untyped fence': '```\n',
  }.entries) {
    test(
      '${fence.key} preserves exact tables headings and indentation',
      () async {
        final model = _ScriptedTranscript([
          fence.value.isEmpty ? markdown : '\n${fence.value}$markdown\n```\n',
        ]);
        expect(await generateValidatedTranscript(model.generate), expected);
        expect(model.hints, ['']);
      },
    );
  }

  test(
    'JSON-looking text is retained literally without interpreting facts',
    () async {
      const text =
          '{"lines":["Synthetic row",12],"facts":"literal source text"}';
      final model = _ScriptedTranscript([text]);
      expect(await generateValidatedTranscript(model.generate), [text]);
      expect(model.hints, ['']);
    },
  );

  test(
    'JSON fences and incomplete Markdown fences remain literal rows',
    () async {
      for (final rows in <List<String>>[
        ['```json', '{"lines":[]}', '```'],
        ['```markdown', '# Synthetic report'],
      ]) {
        final model = _ScriptedTranscript([rows.join('\n')]);
        expect(await generateValidatedTranscript(model.generate), rows);
        expect(model.hints, ['']);
      }
    },
  );

  test('normalizes line endings without changing visible row text', () async {
    final model = _ScriptedTranscript(['  First  \r\nSecond\rThird\n']);
    expect(await generateValidatedTranscript(model.generate), [
      '  First  ',
      'Second',
      'Third',
    ]);
    expect(model.hints, ['']);
  });

  test(
    'bounded repairs keep fixed guidance and never echo rejected text',
    () async {
      const privateMarker = 'SYNTHETIC_REJECTED_PRIVATE_OUTPUT';
      final model = _ScriptedTranscript([
        '$privateMarker${'x' * 2001}',
        List.filled(301, privateMarker).join('\n'),
        '# Synthetic readable report\n| Hb | 11.2 | g/dL |',
      ]);
      expect(await generateValidatedTranscript(model.generate), [
        '# Synthetic readable report',
        '| Hb | 11.2 | g/dL |',
      ]);
      expect(model.hints, hasLength(3));
      expect(model.hints.first, isEmpty);
      expect(model.hints[1], model.hints[2]);
      for (final hint in model.hints.skip(1)) {
        expect(hint, contains('Markdown'));
        expect(hint, contains('300'));
        expect(hint, contains('2000'));
        expect(hint, contains('exact visible text'));
        expect(hint, contains('[unreadable]'));
        expect(hint, isNot(contains(privateMarker)));
        expect(hint, isNot(contains('JSON')));
      }
    },
  );

  for (final invalid in <String, String>{
    'oversized row': 'x' * 2001,
    'too many nonblank rows': List.filled(301, 'Synthetic row').join('\n'),
    'oversized fenced row': '```markdown\n${'x' * 2001}\n```',
  }.entries) {
    test(
      '${invalid.key} stops at three attempts without silent truncation',
      () async {
        final model = _ScriptedTranscript(List.filled(3, invalid.value));
        await expectLater(
          generateValidatedTranscript(model.generate),
          throwsFormatException,
        );
        expect(model.hints, hasLength(3));
        expect(model.hints.first, isEmpty);
        expect(model.hints[1], model.hints[2]);
      },
    );
  }

  test(
    'accepts 300 nonblank rows of 2000 characters without truncation',
    () async {
      final rows = List.filled(300, 'x' * 2000);
      final model = _ScriptedTranscript([rows.join('\n\n')]);
      expect(await generateValidatedTranscript(model.generate), rows);
      expect(model.hints, ['']);
    },
  );

  test(
    'blank images and empty wrapping fences return no invented rows',
    () async {
      for (final raw in ['', ' \n\t\r\n', '```markdown\n\n```']) {
        final model = _ScriptedTranscript([raw]);
        expect(await generateValidatedTranscript(model.generate), isEmpty);
        expect(model.hints, ['']);
      }
    },
  );

  test(
    'blank rows are filtered while readable row spacing and order remain',
    () async {
      final model = _ScriptedTranscript([
        '\n  Synthetic first  \n \nSynthetic second\n',
      ]);
      expect(await generateValidatedTranscript(model.generate), [
        '  Synthetic first  ',
        'Synthetic second',
      ]);
      expect(model.hints, ['']);
    },
  );

  for (final error in <Object>[
    StateError('Synthetic native runtime failure'),
    const FormatException('Synthetic generation context limit'),
  ]) {
    test(
      '${error.runtimeType} during generation propagates without repair',
      () async {
        final model = _ScriptedTranscript([error]);
        await expectLater(
          generateValidatedTranscript(model.generate),
          throwsA(same(error)),
        );
        expect(model.hints, ['']);
      },
    );
  }
}
