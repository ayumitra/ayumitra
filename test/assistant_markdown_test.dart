import 'dart:convert';

import 'package:ayumitra/services/assistant_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'unwraps boxed measurements without changing decimal precision or units',
    () {
      expect(
        normalizeAssistantMarkdown(
          r'\boxed{11.20\,\text{g/dL}} [report:p1:l2]',
        ),
        '11.20 g/dL [report:p1:l2]',
      );
      expect(
        normalizeAssistantMarkdown(r'\boxed{11.2\ \text{g/dL}}'),
        '11.2 g/dL',
      );
      expect(
        normalizeAssistantMarkdown(r'\boxed{\mathrm{120/80}\;\textrm{mmHg}}'),
        '120/80 mmHg',
      );
    },
  );
  test('normalizes simple recognized inline and display math wrappers', () {
    for (final value in [
      r'\(\boxed{98\%}\)',
      r'\[\boxed{98\%}\]',
      r'$\boxed{98\%}$',
      r'$$\boxed{98\%}$$',
    ]) {
      expect(normalizeAssistantMarkdown(value), '98%');
    }
    expect(normalizeAssistantMarkdown(r'$\text{SpO2}=98\%$'), 'SpO2=98%');
    expect(normalizeAssistantMarkdown(r'\text{SpO2}=98\%'), 'SpO2=98%');
  });
  test('known nested wrappers and spacers preserve numeric signs and text', () {
    expect(
      normalizeAssistantMarkdown(
        r'\mathbf{\boxed{-0.05}}\quad\operatorname{mg/L}',
      ),
      '-0.05 mg/L',
    );
    expect(normalizeAssistantMarkdown(r'\boxed{36.70\!\text{°C}}'), '36.70°C');
  });
  test('number-leading clinical math keeps exact readings and known units', () {
    const cases = {
      r'$11.2\,\text{g/dL}$': '11.2 g/dL',
      r'$11.20 \mathrm{g/dL}$': '11.20 g/dL',
      r'$37.2 °C$': '37.2 °C',
      r'$98.6 °F$': '98.6 °F',
      r'$98\%$': '98%',
      r'$72\;\mathrm{bpm}$': '72 bpm',
      r'$120/80 mmHg$': '120/80 mmHg',
      r'$90 \text{mg/dL}$': '90 mg/dL',
      r'$7.4 \mathrm{x10^9/L}$': '7.4 x10^9/L',
      r'$7.40 x10^9/L$': '7.40 x10^9/L',
    };
    for (final entry in cases.entries) {
      final result = normalizeAssistantMarkdown(entry.key);
      expect(result, entry.value);
      expect(hasUnsupportedAssistantFormatting(result), false);
    }
  });
  test('numeric dollar prices are not mistaken for clinical measurements', () {
    for (final input in [
      r'$10',
      r'$10$',
      r'$10 for lunch$',
      r'$10\text{ USD}$',
      r'$10 \text{EUR}$',
    ]) {
      expect(normalizeAssistantMarkdown(input), input);
    }
  });
  test('a whole Markdown envelope is unwrapped before math normalization', () {
    for (final label in ['markdown', 'md']) {
      final input =
          '```$label\n**Hemoglobin:** '
          r'$11.2\,\text{g/dL}$'
          ' [report:p1:l2]\n```';
      expect(
        normalizeAssistantMarkdown(input),
        '**Hemoglobin:** 11.2 g/dL [report:p1:l2]',
      );
    }
  });
  test('mixed Markdown fences and genuine code fences remain intact', () {
    const mixed =
        'Introduction\n```markdown\n'
        r'\boxed{11.2}'
        '\n```\nClosing';
    const dart =
        '```dart\n'
        r'\boxed{11.2}'
        '\n```';
    const json = '```json\n{"answer":"11.2"}\n```';
    expect(normalizeAssistantMarkdown(mixed), mixed);
    expect(normalizeAssistantMarkdown(dart), dart);
    expect(normalizeAssistantMarkdown(json), json);
    expect(hasUnsupportedAssistantFormatting(json), true);
  });
  test('ordinary Markdown and clinical references are unchanged', () {
    const value =
        '**Hemoglobin:** 11.2 g/dL [report:p1:l2]\n\n- Date: 2026-03-14\n- BP: 120/80 mmHg';
    expect(normalizeAssistantMarkdown(value), value);
    expect(hasUnsupportedAssistantFormatting(value), false);
  });
  test(
    'currency, ordinary operators, and ordinary curly braces are unchanged',
    () {
      for (final value in [
        r'Costs $5 or $10.',
        'Use {a, b} and 2 * 3 = 6.',
        r'The price is \$5.',
        '[reviewed] Not JSON',
      ]) {
        expect(normalizeAssistantMarkdown(value), value);
        expect(hasUnsupportedAssistantFormatting(value), false);
      }
    },
  );
  test(
    'remaining math delimiters request repair without changing formulas',
    () {
      for (final value in [
        r'$x + y$',
        r'$$13 kg$$',
        r'\(a+b\)',
        r'\[x=2\]',
        r'\(unfinished',
      ]) {
        expect(normalizeAssistantMarkdown(value), value);
        expect(hasUnsupportedAssistantFormatting(value), true, reason: value);
      }
      for (final value in [
        r'Costs $5 or $10.',
        r'The price is \$5.',
        r'`$x+y$`',
        r'C:\(archive)',
      ]) {
        expect(hasUnsupportedAssistantFormatting(value), false, reason: value);
      }
    },
  );

  test('paths and literal backslash-newline sequences are untouched', () {
    for (final value in [
      r'C:\text{reports}\new\note.txt',
      r'/tmp/\boxed{archive}',
      r'Notes\nremain literal',
      r'\\server\text{notes}',
    ]) {
      expect(normalizeAssistantMarkdown(value), value);
      expect(hasUnsupportedAssistantFormatting(value), false);
    }
  });
  test('only a complete JSON string is decoded for escaped newlines', () {
    expect(
      normalizeAssistantMarkdown(jsonEncode('First line\nSecond line')),
      'First line\nSecond line',
    );
    expect(
      normalizeAssistantMarkdown(r'"First line\nSecond line"'),
      'First line\nSecond line',
    );
    expect(
      normalizeAssistantMarkdown(r'Not JSON: "a\nb"'),
      r'Not JSON: "a\nb"',
    );
  });
  test('fenced and inline code remain byte-for-byte intact', () {
    const code = '```dart\r\n\\boxed{11.2} and \\frac{1}{2}\r\n```\r\n';
    expect(normalizeAssistantMarkdown(code), code);
    expect(hasUnsupportedAssistantFormatting(code), false);
    const inline = r'Code `\boxed{11.2}` and ``\frac{1}{2}`` stays.';
    expect(normalizeAssistantMarkdown(inline), inline);
    expect(hasUnsupportedAssistantFormatting(inline), false);
  });
  test('normalization resumes after fenced code', () {
    const input = '~~~text\n\\boxed{11.2}\n~~~\n\\boxed{98\\%}\n';
    const expected = '~~~text\n\\boxed{11.2}\n~~~\n98%\n';
    expect(normalizeAssistantMarkdown(input), expected);
  });
  test('complex or incomplete math is retained for format repair', () {
    for (final value in [
      r'$\frac{1}{2}$',
      r'\boxed{\sqrt{2}}',
      r'\boxed{11.2',
      r'\(\boxed{11.2}',
      r'\boxed{10^3}',
      r'\text{Hb}_{2}',
    ]) {
      final normalized = normalizeAssistantMarkdown(value);
      if (value != r'\text{Hb}_{2}') expect(normalized, value);
      expect(hasUnsupportedAssistantFormatting(value), true);
    }
  });
  test('normalized simple math needs no format repair', () {
    expect(
      hasUnsupportedAssistantFormatting(
        normalizeAssistantMarkdown(
          r'$\boxed{11.2\,\text{g/dL}}$ [report:p1:l2]',
        ),
      ),
      false,
    );
  });
  test('top-level JSON objects, arrays and JSON fences require repair', () {
    for (final value in [
      '{"answer":"98%"}',
      '[{"answer":"98%"}]',
      '{"answer":',
      '```json\n{"answer":"98%"}\n```',
    ]) {
      expect(hasUnsupportedAssistantFormatting(value), true);
    }
    expect(hasUnsupportedAssistantFormatting('- First\n- Second'), false);
    expect(hasUnsupportedAssistantFormatting('[report:p1:l2]'), false);
  });
}
