import 'clinical_date.dart';
import 'records.dart';

/// discovered report date: a trusted clinical date from original source
/// rows, or a filing-date fallback when sources are dateless or ambiguous.
class ReportDate {
  const ReportDate({
    required this.date,
    required this.isFallback,
    this.sourceLineId,
  });
  final DateTime date;
  final bool isFallback;
  final String? sourceLineId;
}

/// Discovers the clinical date from original source-line content only —
// never from model output or Markdown instructions. Exactly one distinct
/// trusted date across all rows wins; a clinical/date label on the carrying
/// row is preferred for provenance, and birth dates are never accepted.
/// Zero or several distinct dates fall back to the current calendar day with
/// [ReportDate.isFallback] set, for the caller to label as filing date.
ReportDate discoverReportDate(List<SourceLine> lines, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final filing = DateTime.utc(reference.year, reference.month, reference.day);
  final candidates = <String, DateTime>{};
  for (final line in lines) {
    final date = discoverTrustedDate(line.text, now: reference);
    if (date != null) candidates.putIfAbsent(line.id, () => date);
  }
  if (candidates.values.toSet().length != 1) {
    return ReportDate(date: filing, isFallback: true);
  }
  final date = candidates.values.first;
  String? preferred;
  for (final line in lines) {
    if (candidates[line.id] == date && _dateLabel.hasMatch(line.text)) {
      preferred = line.id;
      break;
    }
  }
  preferred ??= candidates.entries.firstWhere((e) => e.value == date).key;
  return ReportDate(date: date, isFallback: false, sourceLineId: preferred);
}

/// Best-effort category from source content. Ordinary document kinds only;
/// anything else is `other`. Never throws and never needs a model schema.
String discoverReportCategory(List<SourceLine> lines) {
  final text = lines.map((l) => l.text).join('\n').toLowerCase();
  bool has(RegExp pattern) => pattern.hasMatch(text);
  if (has(RegExp('discharge'))) return 'discharge';
  if (has(RegExp('radiolog|x-ray|xray|\\bmri\\b|ultrasound|ct scan|imaging'))) {
    return 'radiology';
  }
  if (has(RegExp('prescription|refill|pharmacy|\\brx\\b'))) {
    return 'prescription';
  }
  if (has(RegExp('vaccin|immuniz'))) return 'vaccination';
  if (has(
    RegExp('growth chart|growth|head circumference|percentile|\\bheight\\b'),
  )) {
    return 'growth';
  }
  if (has(
    RegExp(
      '\\bcbc\\b|hemoglobin|hemogram|platelet|\\bwbc\\b|glucose|cholesterol|blood test|lab report|urinalysis',
    ),
  )) {
    return 'lab';
  }
  if (has(
    RegExp('clinic note|follow-up|followup|consultation|progress note'),
  )) {
    return 'note';
  }
  return 'other';
}

/// Preference ordering only — never a validity gate. Validity stays with
/// the clinical-date guards.
final _dateLabel = RegExp(
  r'\b(?:report|test|collection|visit|issued|reported|date)\b',
  caseSensitive: false,
);
