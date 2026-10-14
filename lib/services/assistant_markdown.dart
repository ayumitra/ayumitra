import 'dart:convert';

const _wrappers = {
  'boxed',
  'text',
  'textrm',
  'mathrm',
  'mathbf',
  'operatorname',
};
final _mathCommands = RegExp(
  r'\\(?:boxed|text|textrm|mathrm|mathbf|frac|sqrt|begin|end|left|right|overline|underbrace|textbf|operatorname)\b',
);
final _clinicalUnit = RegExp(
  r'^(?:g/dL|mg/dL|mmHg|bpm|°C|°F|%|[x×]10\^9/L)$',
  caseSensitive: false,
);
final _clinicalMeasurement = RegExp(
  r'^(?:[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)\s*(?:g/dL|mg/dL|mmHg|bpm|°C|°F|%|[x×]10\^9/L)|[0-9]+/[0-9]+\s*mmHg)$',
  caseSensitive: false,
);
final _complexCommands = RegExp(
  r'\\(?:frac|sqrt|begin|end|left|right|overline|underbrace|textbf)\b',
);

/// Removes only a small, lossless subset of model-produced math decoration.
/// Values and units are never parsed, rounded, converted or inferred. Unknown
/// math is retained for a caller's format-repair path, not guessed at here.
String normalizeAssistantMarkdown(String input) {
  var text = input;
  final trimmed = input.trim();
  if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is String) text = decoded;
    } on FormatException {
      // Never globally replace literal backslashes or escaped newlines.
    }
  }
  // Only an entire Markdown envelope is presentation decoration. Code and
  // mixed fenced content keep their original delimiters and bytes.
  final envelope = RegExp(
    r'^\s*(`{3,}|~{3,})(?:markdown|md)[ \t]*\r?\n([\s\S]*?)\r?\n\1[ \t]*\s*$',
    caseSensitive: false,
  ).firstMatch(text);
  if (envelope != null &&
      !RegExp(
        r'^ {0,3}(?:`{3,}|~{3,})',
        multiLine: true,
      ).hasMatch(envelope.group(2)!)) {
    text = envelope.group(2)!;
  }
  return _outsideCode(text, _normalizeProse);
}

/// Signals residual model formatting, without mistaking paths, currencies,
/// ordinary Markdown references or fenced/inline code for medical content.
bool hasUnsupportedAssistantFormatting(String normalized) {
  final trimmed = normalized.trim();
  if (RegExp(
    r'^(?:`{3,}|~{3,})json\b',
    caseSensitive: false,
  ).hasMatch(trimmed)) {
    return true;
  }
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map || decoded is List) return true;
    } on FormatException {
      if (RegExp(r'^\{\s*"[^"\n]+"\s*:').hasMatch(trimmed)) return true;
    }
  }
  var unsupported = false;
  _outsideCode(normalized, (prose) {
    final delimitedMath = RegExp(
      r'\\[([]|(?<!\\)\$\$|(?<![\\$])\$(?![\s$])[^$\n]*?\S\$(?![\d$])',
    ).allMatches(prose).any((m) => _commandBoundary(prose, m.start));
    if (delimitedMath ||
        _mathCommands
            .allMatches(prose)
            .any((m) => _commandBoundary(prose, m.start))) {
      unsupported = true;
    }
    return prose;
  });
  return unsupported;
}

bool _commandBoundary(String text, int index) =>
    index == 0 || !RegExp(r'[A-Za-z0-9_:/\\.]').hasMatch(text[index - 1]);

String _normalizeProse(String input) {
  // Do not partly rewrite complex formulas. A repair loop can ask for prose.
  if (_complexCommands
      .allMatches(input)
      .any((m) => _commandBoundary(input, m.start))) {
    return input;
  }
  if (_mathCommands.hasMatch(input) && RegExp(r'\}[_^]').hasMatch(input)) {
    return input;
  }
  final result = StringBuffer();
  var i = 0;
  var mathSeen = false;
  var lastCommandEnd = -1;
  while (i < input.length) {
    final opening = input.startsWith(r'\(', i)
        ? r'\('
        : input.startsWith(r'\[', i)
        ? r'\['
        : input.startsWith(r'$$', i)
        ? r'$$'
        : input[i] == r'$' && (i == 0 || input[i - 1] != r'\')
        ? r'$'
        : null;
    if (opening != null) {
      final closing = opening == r'\('
          ? r'\)'
          : opening == r'\['
          ? r'\]'
          : opening;
      final end = input.indexOf(closing, i + opening.length);
      if (end < 0) {
        result.write(input.substring(i));
        break;
      }
      final body = input.substring(i + opening.length, end);
      final parsed = _sequence(body, 0, nested: false);
      // Starting with a known command keeps currency expressions conservative.
      final startsMath = RegExp(
        r'^\s*\\(?:boxed|text|textrm|mathrm|mathbf|operatorname)\b',
      ).hasMatch(body);
      if (_clinicalMeasurement.hasMatch(body.trim())) {
        result.write(body.trim());
      } else if (parsed != null &&
          parsed.end == body.length &&
          ((startsMath && parsed.known) ||
              _clinicalMeasurement.hasMatch(parsed.text.trim()))) {
        result.write(parsed.text.trim());
      } else {
        result.write(input.substring(i, end + closing.length));
      }
      i = end + closing.length;
      continue;
    }
    if (input[i] == r'\' &&
        (_commandBoundary(input, i) ||
            (mathSeen &&
                (i == lastCommandEnd || input.startsWith(r'\%', i))))) {
      final command = _command(input, i);
      if (command != null) {
        result.write(command.text);
        mathSeen = true;
        i = command.end;
        lastCommandEnd = i;
        continue;
      }
      // An incomplete known wrapper must stay intact, including inner text.
      if (RegExp(
        r'^\\(?:boxed|text|textrm|mathrm|mathbf|operatorname)\b',
      ).hasMatch(input.substring(i))) {
        result.write(input.substring(i));
        break;
      }
    }
    result.write(input[i++]);
  }
  return result.toString();
}

class _Parsed {
  const _Parsed(this.text, this.end, {this.known = true});
  final String text;
  final int end;
  final bool known;
}

_Parsed? _command(String input, int start) {
  if (start + 1 >= input.length || input[start] != r'\') return null;
  final next = input[start + 1];
  if (next == ',' || next == ';' || next == ' ') return _Parsed(' ', start + 2);
  if (next == '!') return _Parsed('', start + 2);
  if (next == '%') return _Parsed('%', start + 2);
  final word = RegExp(r'^[A-Za-z]+').firstMatch(input.substring(start + 1));
  if (word == null) return null;
  final name = word.group(0)!;
  var cursor = start + 1 + name.length;
  if (name == 'quad' || name == 'qquad') return _Parsed(' ', cursor);
  if (!_wrappers.contains(name)) return null;
  while (cursor < input.length &&
      (input[cursor] == ' ' || input[cursor] == '\t')) {
    cursor++;
  }
  if (cursor >= input.length || input[cursor] != '{') return null;
  final directClose = input.indexOf('}', cursor + 1);
  if (directClose >= 0) {
    final unit = input.substring(cursor + 1, directClose);
    if (_clinicalUnit.hasMatch(unit)) return _Parsed(unit, directClose + 1);
  }
  final inner = _sequence(input, cursor + 1, nested: true);
  if (inner == null) return null;
  return _Parsed(inner.text, inner.end);
}

_Parsed? _sequence(String input, int start, {required bool nested}) {
  final result = StringBuffer();
  var i = start;
  var known = false;
  while (i < input.length) {
    if (input[i] == '}') {
      return nested ? _Parsed(result.toString(), i + 1, known: known) : null;
    }
    if (input[i] == '{') {
      // Raw grouping is not one of the explicitly supported wrappers.
      return null;
    }
    if (input[i] == r'\') {
      final parsed = _command(input, i);
      if (parsed == null) return null;
      result.write(parsed.text);
      known = true;
      i = parsed.end;
      continue;
    }
    // Superscripts/subscripts and alignment require a real math renderer.
    if (input[i] == '^' ||
        input[i] == '_' ||
        input[i] == '&' ||
        input[i] == r'$') {
      return null;
    }
    result.write(input[i++]);
  }
  return nested ? null : _Parsed(result.toString(), i, known: known);
}

String _outsideCode(String input, String Function(String) mapProse) {
  final result = StringBuffer(), prose = StringBuffer();
  String? marker;
  var markerLength = 0;
  void flush() {
    if (prose.isEmpty) return;
    result.write(_outsideInlineCode(prose.toString(), mapProse));
    prose.clear();
  }

  for (final match in RegExp(r'[^\r\n]*(?:\r\n|\n|\r|$)').allMatches(input)) {
    final line = match.group(0)!;
    if (line.isEmpty) continue;
    if (marker != null) {
      result.write(line);
      if (RegExp(
        '^ {0,3}${RegExp.escape(marker)}{$markerLength,}[ \\t]*(?:\\r?\\n|\\r)?\$',
      ).hasMatch(line)) {
        marker = null;
      }
      continue;
    }
    final fence = RegExp(r'^ {0,3}(`{3,}|~{3,})').firstMatch(line);
    if (fence != null) {
      flush();
      final run = fence.group(1)!;
      marker = run[0];
      markerLength = run.length;
      result.write(line);
    } else {
      prose.write(line);
    }
  }
  flush();
  return result.toString();
}

String _outsideInlineCode(String input, String Function(String) mapProse) {
  final result = StringBuffer();
  var cursor = 0;
  while (cursor < input.length) {
    final opening = input.indexOf('`', cursor);
    if (opening < 0) {
      result.write(mapProse(input.substring(cursor)));
      break;
    }
    result.write(mapProse(input.substring(cursor, opening)));
    var endRun = opening;
    while (endRun < input.length && input[endRun] == '`') {
      endRun++;
    }
    final delimiter = input.substring(opening, endRun);
    final closing = input.indexOf(delimiter, endRun);
    if (closing < 0) {
      result.write(input.substring(opening));
      break;
    }
    result.write(input.substring(opening, closing + delimiter.length));
    cursor = closing + delimiter.length;
  }
  return result.toString();
}
