import 'package:ayumitra/domain/extraction.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:flutter_test/flutter_test.dart';

SourceLine _line(String id, String text) => SourceLine(
  id: id,
  page: 2,
  text: text,
  method: 'vision',
  bounds: const [10, 20, 300, 30],
  pageWidth: 600,
  pageHeight: 800,
);

MedicalFact _fact(String lineId, {bool corrected = true}) => MedicalFact(
  id: '$lineId:lab:hb',
  kind: 'lab',
  name: 'Hb',
  value: corrected ? '11.9' : '11.2',
  unit: 'g/dL',
  range: '',
  sourceLineId: lineId,
  evidence: 'Hb 11.2 g/dL',
  corrected: corrected,
  originalValue: corrected ? '11.2' : null,
);

void main() {
  test(
    'changed vision row order follows exact evidence, not previous row ID',
    () {
      final result = reconcileSourceCorrections(
        previousFacts: [_fact('p2-l1')],
        previousLines: [_line('p2-l1', 'Hb 11.2 g/dL')],
        newLines: [
          _line('p2-l1', 'Platelets 250'),
          _line('p2-l2', 'Hb 11.2 g/dL'),
        ],
      );
      expect(result.lines.length, 2);
      expect(result.corrections.single.sourceLineId, 'p2-l2');
      expect(result.corrections.single.id, 'p2-l2:lab:hb');
      expect(result.corrections.single.value, '11.9');
      expect(result.corrections.single.originalValue, '11.2');
      final merged = preserveCorrections([
        _fact('p2-l2', corrected: false),
      ], result.corrections);
      expect(merged.single.corrected, true);
      expect(merged.single.value, '11.9');
    },
  );

  test(
    'missing evidence retains the true old source with original geometry',
    () {
      final result = reconcileSourceCorrections(
        previousFacts: [_fact('p2-l1')],
        previousLines: [_line('p2-l1', 'Hb 11.2 g/dL')],
        newLines: [_line('p2-l1', 'Platelets 250')],
      );
      final correction = result.corrections.single;
      final source = result.lines.singleWhere(
        (line) => line.id == correction.sourceLineId,
      );
      expect(correction.sourceLineId.startsWith('prior-p2-l1-'), true);
      expect(source.text, 'Hb 11.2 g/dL');
      expect(source.method, 'prior-vision');
      expect(source.page, 2);
      expect(source.bounds, [10, 20, 300, 30]);
      expect(source.pageWidth, 600);
      expect(source.pageHeight, 800);
      expect(result.lines.first.text, 'Platelets 250');
      final retained = preserveCorrections([], result.corrections);
      expect(retained.single.value, '11.9');
      expect(retained.single.sourceLineId, source.id);
    },
  );

  test(
    'duplicate new evidence cannot arbitrarily choose a corrected source',
    () {
      final result = reconcileSourceCorrections(
        previousFacts: [_fact('p2-l1')],
        previousLines: [_line('p2-l1', 'Hb 11.2 g/dL')],
        newLines: [
          _line('p2-l1', 'Hb 11.2 g/dL'),
          _line('p2-l2', 'Hb 11.2 g/dL'),
        ],
      );
      expect(result.corrections.single.sourceLineId.startsWith('prior-'), true);
      expect(result.lines.length, 3);
    },
  );

  test('noncorrected facts do not survive transcript replacement', () {
    final result = reconcileSourceCorrections(
      previousFacts: [_fact('p2-l1', corrected: false)],
      previousLines: [_line('p2-l1', 'Hb 11.2 g/dL')],
      newLines: [_line('p2-l1', 'Platelets 250')],
    );
    expect(result.corrections.length, 0);
    expect(result.lines.length, 1);
  });

  test('historical sources remain stable across repeated processing', () {
    final first = reconcileSourceCorrections(
      previousFacts: [_fact('p2-l1')],
      previousLines: [_line('p2-l1', 'Hb 11.2 g/dL')],
      newLines: [_line('p2-l1', 'Platelets 250')],
    );
    final second = reconcileSourceCorrections(
      previousFacts: first.corrections,
      previousLines: first.lines,
      newLines: [_line('p2-l1', 'Platelets 250')],
    );
    expect(
      second.corrections.single.sourceLineId,
      first.corrections.single.sourceLineId,
    );
    expect(second.lines.last.method, 'prior-vision');
    expect(second.lines.length, 2);
  });

  test(
    'missing original source refuses replacement instead of losing correction',
    () {
      expect(
        () => reconcileSourceCorrections(
          previousFacts: [_fact('missing')],
          previousLines: [],
          newLines: [_line('p2-l1', 'Hb 11.2 g/dL')],
        ),
        throwsFormatException,
      );
    },
  );
}
