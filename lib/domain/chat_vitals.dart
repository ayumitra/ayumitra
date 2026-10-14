import 'conversations.dart';
import 'companion_intent.dart';
import 'vitals.dart';

/// Extracts explicit user-reported readings from a persisted user turn. This
/// never infers diagnoses, units, missing values or another profile's identity.
/// The caller supplies the already-selected owner and the original turn time.
///
/// Only clear declarations are eligible. Questions, examples, negation and
/// hypothetical instructions are ignored. A declaration followed by a question
/// can still contribute its reading. More than one different reading of the
/// same kind in one turn is left for clarification, rather than silently picking
/// one. Stable turn/kind IDs make replay idempotent at the caller's insertion.
List<VitalEntry> extractChatVitals({
  required String text,
  required String profileId,
  required String turnId,
  required DateTime providedAt,
}) {
  if (profileId.trim().isEmpty || turnId.trim().isEmpty) return const [];
  final cleaned = _withoutQuotedExamples(text);
  if (cleaned.trim().isEmpty) return const [];
  if (RegExp(
    r'^(?:for\s+example|(?:a|an)\s+example|hypothetically|hypothetical|pretend|imagine|suppose|assuming|sample)\b',
    caseSensitive: false,
  ).hasMatch(cleaned.trim())) {
    return const [];
  }
  final start = _unwrapMemoryRequest(cleaned.trim());
  // A request's supplied sample values are not new patient observations.
  if (isAssistantRequest(start) && !_startsAsDeclaration(start)) {
    return const [];
  }
  final clauses = _clauses(start).where(_isAffirmative).toList();
  if (clauses.isEmpty) return const [];
  final dateResults = clauses
      .map((clause) => _eventDate(clause, providedAt))
      .toList();
  final explicitDays = dateResults
      .where((date) => date.hasDate && date.valid)
      .map((date) => date.date!)
      .toSet();
  final invalidDate = dateResults.any((date) => date.hasDate && !date.valid);
  final candidates = <VitalKind, List<VitalEntry>>{};

  for (var index = 0; index < clauses.length; index++) {
    final clause = _unwrapMemoryRequest(clauses[index]);
    if (!_startsAsDeclaration(clause)) continue;
    final event = dateResults[index];
    if (!event.valid || (!event.hasDate && invalidDate)) continue;
    // A unique explicit date applies to the turn's undated declarations. With
    // distinct explicit dates, an undated clause is ambiguous and is skipped.
    if (!event.hasDate && explicitDays.length > 1) continue;
    var measuredAt = event.hasDate
        ? event.date!
        : explicitDays.isNotEmpty
        ? explicitDays.single
        : providedAt;
    // Explicit clock times belong to the user's measurement date, not the
    // message time. Keep date-only readings as calendar dates in their zone.
    final clock = RegExp(
      r'\bat\s+(\d{1,2}):(\d{2})(?:\s*(am|pm))?\b',
      caseSensitive: false,
    ).firstMatch(clause);
    if (clock != null) {
      var hour = int.parse(clock.group(1)!);
      final minute = int.parse(clock.group(2)!);
      final period = clock.group(3)?.toLowerCase();
      if (minute > 59 || (period == null ? hour > 23 : hour < 1 || hour > 12)) {
        continue;
      }
      if (period != null) hour = hour % 12 + (period == 'pm' ? 12 : 0);
      measuredAt = providedAt.isUtc
          ? DateTime.utc(
              measuredAt.year,
              measuredAt.month,
              measuredAt.day,
              hour,
              minute,
            )
          : DateTime(
              measuredAt.year,
              measuredAt.month,
              measuredAt.day,
              hour,
              minute,
            );
      if (measuredAt.isAfter(providedAt)) continue;
    }

    void record(VitalKind kind, String raw, String unit, {String? secondary}) {
      final value = double.tryParse(raw);
      final other = secondary == null ? null : double.tryParse(secondary);
      if (value == null ||
          !value.isFinite ||
          (secondary != null && other == null)) {
        return;
      }
      final entry = VitalEntry(
        id: 'chat:$turnId:${kind.name}',
        profileId: profileId,
        kind: kind,
        value: value,
        secondaryValue: other,
        unit: unit,
        measuredAt: measuredAt,
        source: 'user',
        note:
            'User-reported in conversation turn $turnId. Original statement: $text',
      );
      try {
        addVital(const [], entry);
      } on FormatException {
        return;
      } on StateError {
        return;
      }
      candidates.putIfAbsent(kind, () => []).add(entry);
    }

    for (final match in _bloodPressure.allMatches(clause)) {
      if (match.group(1) == null && match.group(4) == null) continue;
      if (match.group(4) == null &&
          RegExp(
            r'^\s*(?:kpa|bpm|cm|kg|mmol|mg|°|%|celsius|fahrenheit)\b',
            caseSensitive: false,
          ).hasMatch(clause.substring(match.end))) {
        continue;
      }
      record(
        VitalKind.bloodPressure,
        match.group(2)!,
        'mmHg',
        secondary: match.group(3),
      );
    }
    for (final match in _oxygen.allMatches(clause)) {
      record(VitalKind.spo2, match.group(1)!, '%');
    }
    for (final match in _pulse.allMatches(clause)) {
      record(VitalKind.pulse, match.group(1)!, 'bpm');
    }
    for (final match in _temperature.allMatches(clause)) {
      final unit = match.group(2)!.toLowerCase();
      record(
        VitalKind.temperature,
        match.group(1)!,
        unit.contains('f') ? '°F' : '°C',
      );
    }
    for (final match in _heightCm.allMatches(clause)) {
      record(VitalKind.height, match.group(1) ?? match.group(2)!, 'cm');
    }
    for (final match in _heightM.allMatches(clause)) {
      // Meters must be a plausible person-scale value; anything else is a
      // unit mix-up that validation would otherwise misread as centimeters.
      final meters = double.tryParse(match.group(1)!);
      if (meters == null || meters <= 0 || meters > 3) continue;
      record(VitalKind.height, (meters * 100).toStringAsFixed(3), 'cm');
    }
    for (final match in _heightFtIn.allMatches(clause)) {
      // A lone `5'` with no inches and no height word is too ambiguous
      // (time, shorthand) to record; fuller forms are distinctive.
      if (match.group(2) == "'" &&
          match.group(3) == null &&
          !RegExp(
            r'\b(?:height|tall)\b',
            caseSensitive: false,
          ).hasMatch(clause)) {
        continue;
      }
      final feet = double.tryParse(match.group(1)!);
      final inches = match.group(3) == null
          ? 0.0
          : double.tryParse(match.group(3)!) ?? -1;
      if (feet == null || inches < 0) continue;
      record(
        VitalKind.height,
        ((feet * 12 + inches) * 2.54).toStringAsFixed(3),
        'cm',
      );
    }
    for (final match in _weightKg.allMatches(clause)) {
      record(VitalKind.weight, match.group(1)!, 'kg');
    }
    for (final match in _weightLb.allMatches(clause)) {
      final pounds = double.tryParse(match.group(1)!);
      if (pounds == null) continue;
      record(VitalKind.weight, (pounds * 0.45359237).toStringAsFixed(3), 'kg');
    }
    for (final match in _weightBare.allMatches(clause)) {
      record(VitalKind.weight, match.group(1)!, 'kg');
    }
    for (final match in _heightBare.allMatches(clause)) {
      record(VitalKind.height, match.group(1)!, 'cm');
    }
    for (final match in _tempBare.allMatches(clause)) {
      final unit = match.group(2)!.toLowerCase();
      record(
        VitalKind.temperature,
        match.group(1)!,
        unit.contains('f') ? '°F' : '°C',
      );
    }
    for (final match in _pulseBare.allMatches(clause)) {
      record(VitalKind.pulse, match.group(1)!, 'bpm');
    }
  }
  final result = <VitalEntry>[];
  for (final rows in candidates.values) {
    final first = rows.first;
    if (rows.every(
      (row) =>
          row.value == first.value &&
          row.secondaryValue == first.secondaryValue &&
          row.unit == first.unit &&
          row.measuredAt == first.measuredAt,
    )) {
      result.add(first);
    }
  }
  return result;
}

String _withoutQuotedExamples(String text) => text
    .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
    .replaceAll(RegExp(r'`[^`]*`'), ' ')
    .replaceAll(RegExp(r'"[^"\n]*"|“[^”\n]*”|‘[^’\n]*’'), ' ')
    .replaceAll(RegExp(r"(^|\s)'[^'\n]+'(?=\s|[.,;!?]|$)"), ' ')
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('>'))
    .join('\n');

String _unwrapMemoryRequest(String text) => text
    .replaceFirst(
      RegExp(
        r'^(?:please\s+)?(?:remember|record|save|log|track|note|add|update)(?:\s+that)?\s+',
        caseSensitive: false,
      ),
      '',
    )
    .trim();

bool _startsAsDeclaration(String text) => RegExp(
  r'^(?:(?:today|yesterday)\s*[,;:]?\s*)?(?:(?:(?:my|our|his|her|their)\s+)?(?:blood\s+pressure|bp\b|spo[2₂](?!\w)|oxygen\s+saturation|o[2₂]\s+saturation|pulse\b|heart\s*rate|temperature\b|temp\b|height\b|weight\b|weighs?\b|tall\b)|i(?:['
  "'’"
  r']?m\b|\s+am\b|\s+weigh\b|\s+(?:measured|recorded|checked|have|had))|\d)',
  caseSensitive: false,
).hasMatch(text);

List<String> _clauses(String text) {
  final pieces = <String>[];
  var start = 0;
  for (var index = 0; index < text.length; index++) {
    final character = text[index];
    final decimal =
        character == '.' &&
        index > 0 &&
        index + 1 < text.length &&
        RegExp(r'\d').hasMatch(text[index - 1]) &&
        RegExp(r'\d').hasMatch(text[index + 1]);
    if ('\n;?!'.contains(character) || (character == '.' && !decimal)) {
      pieces.add(text.substring(start, index + 1));
      start = index + 1;
    }
  }
  if (start < text.length) pieces.add(text.substring(start));
  final questionTransition = RegExp(
    r'(?:,\s*|\s+(?:and|but)\s+)(?=(?:what|why|how|when|where|which|is|are|was|were|do|does|did|can|could|should|would|will)\b)',
    caseSensitive: false,
  );
  return [
    for (final piece in pieces) ...piece.split(questionTransition),
  ].map((piece) => piece.trim()).where((piece) => piece.isNotEmpty).toList();
}

bool _isAffirmative(String raw) {
  final text = _unwrapMemoryRequest(raw);
  if (text.endsWith('?') ||
      _uncertain.hasMatch(text) ||
      _exampleContext.hasMatch(text)) {
    return false;
  }
  if (isAssistantRequest(text)) return false;
  return true;
}

final _exampleContext = RegExp(
  r'\b(?:hypothetical|hypothetically|example|sample\s+(?:reading|value|measurement)|pretend|imagine|suppose|assuming|what\s+if)\b',
  caseSensitive: false,
);
final _uncertain = RegExp(
  r"\b(?:not|never|neither|without|no\s+(?:reading|measurement)|didn.t|doesn.t|don.t|hadn.t|wasn.t|weren.t|isn.t|aren.t|haven.t|hasn.t|can.t|cannot|couldn.t|would|should|might|could|maybe|perhaps|possibly|approximately|around|about|rather\s+than|instead\s+of)\b",
  caseSensitive: false,
);
const _number = r'(-?\d+(?:\.\d+)?)';
const _link =
    r'(?:\s+(?:is|was|at|of|reading|measured|recorded|as|reads|read))*\s*[:=]?\s*';
final _bloodPressure = RegExp(
  r'(?<![\w./])(?:(blood\s+pressure|bp)\b' +
      _link +
      r')?' +
      _number +
      r'\s*/\s*' +
      _number +
      r'(?:\s*(mm\s*hg)\b)?(?![\d/]|\.\d)',
  caseSensitive: false,
);
final _oxygen = RegExp(
  r'\b(?:spo[2₂]|(?:oxygen|o[2₂])\s+(?:saturation|sat))(?!\w)' +
      _link +
      _number +
      r'\s*(?:%|percent(?:age)?\b)(?!\w)',
  caseSensitive: false,
);
final _pulse = RegExp(
  r'\b(?:pulse|heart\s*rate)\b' + _link + _number + r'\s*bpm\b',
  caseSensitive: false,
);
final _temperature = RegExp(
  r'\b(?:temperature|temp)\b' +
      _link +
      _number +
      r'\s*(°\s*[cf]\b|[cf]\b|celsius\b|fahrenheit\b|degrees?\s*(?:celsius|fahrenheit|[cf])\b)',
  caseSensitive: false,
);
final _heightCm = RegExp(
  r'(?:\bheight\b' +
      _link +
      _number +
      r'\s*(?:cm\b|centimet(?:er|re)s?\b)|' +
      _number +
      r'\s*(?:cm\b|centimet(?:er|re)s?\b)\s+tall\b)',
  caseSensitive: false,
);
final _heightM = RegExp(
  r'\bheight\b' + _link + _number + r'\s*(?:m\b|met(?:er|re)s?\b)',
  caseSensitive: false,
);
final _heightFtIn = RegExp(
  r"\b(\d)\s*("
  "'"
  r"|ft\b|feet\b)\s*(\d+(?:\.\d+)?)?\s*("
  '"'
  r"|in\b|inch(?:es)?\b)?",
  caseSensitive: false,
);
final _weightKg = RegExp(
  r'\b(?:weight|weighs?)\b' +
      _link +
      _number +
      r'\s*(?:kg\b|kilos?\b|kilograms?\b)',
  caseSensitive: false,
);
final _weightLb = RegExp(
  r'\b(?:weight|weighs?)\b' + _link + _number + r'\s*(?:lbs?\b|pounds?\b)',
  caseSensitive: false,
);
// Copular first-person forms without a metric keyword ("I'm 70 kg").
// Only units that cannot plausibly mean anything else: never bare %
// (confidence) and never bare ratios (existing BP rule stays).
const _copularSrc = "\\bi(?:['’]?m|\\s+am)\\b";
final _weightBare = RegExp(
  _copularSrc + _link + _number + r'\s*(?:kg\b|kilos?\b|kilograms?\b)',
  caseSensitive: false,
);
final _heightBare = RegExp(
  _copularSrc + _link + _number + r'\s*(?:cm\b|centimet(?:er|re)s?\b)',
  caseSensitive: false,
);
final _tempBare = RegExp(
  _copularSrc + _link + _number + r'\s*(°\s*[cf]\b|celsius\b|fahrenheit\b)',
  caseSensitive: false,
);
final _pulseBare = RegExp(
  _copularSrc + _link + _number + r'\s*bpm\b',
  caseSensitive: false,
);

class _EventDate {
  const _EventDate({required this.hasDate, required this.valid, this.date});
  final bool hasDate;
  final bool valid;
  final DateTime? date;
}

_EventDate _eventDate(String text, DateTime providedAt) {
  if (RegExp(
    r'\b(?:tomorrow|next\s+(?:week|month|year)|last\s+night|in\s+\d+\s+days?)\b',
    caseSensitive: false,
  ).hasMatch(text)) {
    return const _EventDate(hasDate: true, valid: false);
  }
  final filter = reportDateFilterForRequest(text, providedAt);
  if (filter == null) {
    final unsupportedDate = RegExp(
      r'\b(?:january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept?|oct|nov|dec)\.?\s+\d{1,2}\b|\b\d{1,2}[-/.]\d{1,2}[-/.]\d{2}\b',
      caseSensitive: false,
    ).hasMatch(text);
    return _EventDate(hasDate: unsupportedDate, valid: !unsupportedDate);
  }
  if (filter.ambiguous || filter.windows.isEmpty) {
    return const _EventDate(hasDate: true, valid: false);
  }
  final dates = <DateTime>{};
  final today = DateTime.utc(providedAt.year, providedAt.month, providedAt.day);
  for (final window in filter.windows) {
    if (window.end.difference(window.start) != const Duration(days: 1) ||
        window.start.isAfter(today)) {
      return const _EventDate(hasDate: true, valid: false);
    }
    dates.add(window.start);
  }
  if (RegExp(r'\btoday\b', caseSensitive: false).hasMatch(text)) {
    dates.add(today);
  }
  if (RegExp(r'\byesterday\b', caseSensitive: false).hasMatch(text)) {
    dates.add(today.subtract(const Duration(days: 1)));
  }
  if (dates.length != 1) return const _EventDate(hasDate: true, valid: false);
  final date = dates.single;
  return _EventDate(
    hasDate: true,
    valid: true,
    date: providedAt.isUtc ? date : DateTime(date.year, date.month, date.day),
  );
}

/// Removes only readings derived from deleted user turns. Manual measurements
/// and uploaded reports survive conversation deletion.
List<VitalEntry> withoutChatVitals(
  List<VitalEntry> entries,
  ConversationSession session,
) {
  final prefixes = session.turns
      .where((t) => t.role == 'user')
      .map((t) => 'chat:${t.id}:')
      .toList();
  return entries
      .where(
        (v) =>
            v.profileId != session.profileId ||
            !prefixes.any((prefix) => v.id.startsWith(prefix)),
      )
      .toList();
}
