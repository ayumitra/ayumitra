import 'records.dart';

/// Normalizes a model-proposed date only when its exact quoted source supports
/// that date. Ambiguous numeric dates and birth dates are never inferred.
DateTime? validateClinicalDate({
  required String proposed,
  required String evidence,
  required SourceLine source,
  required DateTime now,
}) {
  if (evidence.trim().isEmpty || !source.text.contains(evidence)) return null;
  final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(proposed);
  if (iso == null) return null;
  final candidate = _checkedDate(
    int.parse(iso.group(1)!),
    int.parse(iso.group(2)!),
    int.parse(iso.group(3)!),
  );
  if (candidate == null ||
      candidate.isAfter(DateTime.utc(now.year, now.month, now.day))) {
    return null;
  }

  final matches = _datePattern.allMatches(evidence).toList();
  // A quote containing several dates cannot establish which one is clinical.
  if (matches.length != 1) return null;
  final match = matches.single;
  final normalized = _normalize(match);
  if (normalized != candidate) return null;

  // Check every occurrence: quoting just a date must not strip away a DOB
  // label. If the same date occurs in different contexts, request review.
  var offset = 0;
  var occurrences = 0;
  while (offset <= source.text.length) {
    final start = source.text.indexOf(evidence, offset);
    if (start < 0) break;
    occurrences++;
    final before = source.text.substring(0, start + match.start);
    final birth = _birthLabel.allMatches(before).lastOrNull;
    final clinical = _clinicalLabel.allMatches(before).lastOrNull;
    if (birth != null && (clinical == null || birth.start > clinical.start)) {
      return null;
    }
    // Some forms print the date before its DOB label.
    final after = source.text.substring(start + match.end);
    if (RegExp(
      r'^\s*(?:\([^)]*)?\b(?:DOB|date\s+of\s+birth|birth\s+date)\b',
      caseSensitive: false,
    ).hasMatch(after)) {
      return null;
    }
    offset = start + evidence.length;
  }
  return occurrences == 1 ? candidate : null;
}

final _birthLabel = RegExp(
  r'\b(?:d\.?o\.?b\.?|date\s+of\s+birth|birth\s*date|born)\b',
  caseSensitive: false,
);
final _clinicalLabel = RegExp(
  r'\b(?:(?:report|test|collection|sample|specimen|visit|examination|exam|admission|discharge|vaccination|clinical|procedure)\s+(?:date|on|at)|admission|discharge|vaccination|issued|reported|date\s+of\s+(?:report|test|collection|visit|admission|discharge|examination|vaccination))\b',
  caseSensitive: false,
);
const _monthExpression =
    r'(?:January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept?|Oct|Nov|Dec)';
final _datePattern = RegExp(
  r'\b(?:(\d{4})[-/](\d{1,2})[-/](\d{1,2})|(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})|(\d{1,2})(?:st|nd|rd|th)?[\s-]+(' +
      _monthExpression +
      r')\.?[\s,-]+(\d{4})|(' +
      _monthExpression +
      r')\.?[\s-]+(\d{1,2})(?:st|nd|rd|th)?[\s,-]+(\d{4}))\b',
  caseSensitive: false,
);

DateTime? _normalize(RegExpMatch match) {
  if (match.group(1) != null) {
    return _checkedDate(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }
  if (match.group(4) != null) {
    final first = int.parse(match.group(4)!);
    final second = int.parse(match.group(5)!);
    if (first <= 12 && second <= 12 && first != second) return null;
    final day = first > 12 ? first : second;
    final month = first > 12 ? second : first;
    return _checkedDate(int.parse(match.group(6)!), month, day);
  }
  const months = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };
  final dayFirst = match.group(7) != null;
  final month = match.group(dayFirst ? 8 : 10)!.toLowerCase();
  return _checkedDate(
    int.parse(match.group(dayFirst ? 9 : 12)!),
    months[month.substring(0, 3)]!,
    int.parse(match.group(dayFirst ? 7 : 11)!),
  );
}

DateTime? _checkedDate(int year, int month, int day) {
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > 31) return null;
  final date = DateTime.utc(year, month, day);
  return date.year == year && date.month == month && date.day == day
      ? date
      : null;
}

/// Trusted discovery of at most one unambiguous supported date in raw
/// source text: ISO, named-month, or unambiguous numeric forms accepted by
/// the guards above. Returns null for zero or several dates, DOB-labelled
/// dates, or future dates. Normalizes only — never infers.
DateTime? discoverTrustedDate(String text, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final matches = _datePattern.allMatches(text).toList();
  if (matches.length != 1) return null;
  final match = matches.single;
  final candidate = _normalize(match);
  if (candidate == null) return null;
  final today = DateTime.utc(reference.year, reference.month, reference.day);
  if (candidate.isAfter(today)) return null;
  final before = text.substring(0, match.start);
  final birth = _birthLabel.allMatches(before).lastOrNull;
  final clinical = _clinicalLabel.allMatches(before).lastOrNull;
  if (birth != null && (clinical == null || birth.start > clinical.start)) {
    return null;
  }
  final after = text.substring(match.end);
  if (RegExp(
    r'^\s*(?:\([^)]*)?\b(?:DOB|date\s+of\s+birth|birth\s+date)\b',
    caseSensitive: false,
  ).hasMatch(after)) {
    return null;
  }
  return candidate;
}
