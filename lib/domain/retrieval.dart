import 'dart:math';

import 'records.dart';

class EvidenceHit {
  const EvidenceHit(this.report, this.line, this.score);
  final Report report;
  final SourceLine line;
  final double score;
  String get citation => '${report.id}/${line.id}';
}

double cosine(List<double> a, List<double> b) {
  if (a.length != b.length ||
      a.isEmpty ||
      a.any((x) => !x.isFinite) ||
      b.any((x) => !x.isFinite)) {
    return 0;
  }
  double dot = 0, aa = 0, bb = 0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    aa += a[i] * a[i];
    bb += b[i] * b[i];
  }
  return aa == 0 || bb == 0 ? 0 : dot / sqrt(aa * bb);
}

/// Filter ownership BEFORE scoring. Rank fusion avoids adding incomparable
/// keyword counts and cosine values. A model-version mismatch disables that vector.
List<EvidenceHit> retrieve({
  required String profileId,
  required List<Report> reports,
  required String query,
  List<double>? queryVector,
  String? embeddingVersion,
  int limit = 12,
}) {
  final stopWords = {
    'the',
    'a',
    'an',
    'my',
    'me',
    'show',
    'find',
    'what',
    'is',
    'was',
    'in',
    'of',
    'for',
    'and',
    'report',
    'reports',
    'summarize',
    'summary',
    'history',
  };
  final tokens = RegExp(r'[a-z0-9]+')
      .allMatches(query.toLowerCase())
      .map((m) => m.group(0)!)
      .where((x) => !stopWords.contains(x))
      .toSet();
  final keyword = <EvidenceHit>[];
  final semantic = <EvidenceHit>[];
  final all = <EvidenceHit>[];
  for (final report in reports.where((r) => r.profileId == profileId)) {
    for (final line in report.lines) {
      // Empty rows mark unreadable pages; they are not evidence for an answer.
      if (line.text.trim().isEmpty) continue;
      final correctedFacts = report.facts.where(
        (f) => f.sourceLineId == line.id && f.corrected,
      );
      final text =
          '${line.text} ${correctedFacts.map((f) => '${f.name} ${f.value} ${f.unit}').join(' ')}'
              .toLowerCase();
      final words = RegExp(
        r'[a-z0-9]+',
      ).allMatches(text).map((m) => m.group(0)!).toSet();
      final count = tokens.where(words.contains).length.toDouble();
      final hit = EvidenceHit(report, line, count);
      all.add(hit);
      if (count > 0) keyword.add(hit);
      final vector = report.vectors[line.id];
      if (queryVector != null &&
          embeddingVersion != null &&
          report.embeddingVersion == embeddingVersion &&
          vector != null) {
        final score = cosine(queryVector, vector);
        if (score > 0) semantic.add(EvidenceHit(report, line, score));
      }
    }
  }
  keyword.sort((a, b) => b.score.compareTo(a.score));
  semantic.sort((a, b) => b.score.compareTo(a.score));
  if (tokens.isEmpty) return all.take(limit).toList();
  final combined = <String, (EvidenceHit, double)>{};
  for (final list in [keyword, semantic]) {
    for (var rank = 0; rank < list.length; rank++) {
      final hit = list[rank];
      combined[hit.citation] = (
        hit,
        (combined[hit.citation]?.$2 ?? 0) + 1 / (60 + rank + 1),
      );
    }
  }
  final sorted = combined.values.toList()..sort((a, b) => b.$2.compareTo(a.$2));
  return sorted.take(limit).map((x) => x.$1).toList();
}
