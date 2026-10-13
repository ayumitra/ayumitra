import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'records.dart';
import 'model_json.dart';

class ExtractionResult {
  const ExtractionResult(this.facts, this.rejected);
  final List<MedicalFact> facts;
  final int rejected;
}

/// A model's output is a proposal. Source IDs and verbatim evidence are checked
/// before anything enters the record. This cannot establish clinical correctness.
ExtractionResult validateExtraction(String response, List<SourceLine> lines) {
  final cleaned = unfenceJson(response);
  final root = jsonDecode(cleaned);
  if (root is! Map || root['facts'] is! List) {
    throw const FormatException('Expected fact proposals.');
  }
  final sources = {for (final line in lines) line.id: line};
  final facts = <MedicalFact>[];
  var rejected = 0;
  final seen = <String>{};
  for (final raw in root['facts']) {
    if (raw is! Map) {
      rejected++;
      continue;
    }
    final fields = [
      'kind',
      'name',
      'value',
      'unit',
      'range',
      'sourceLineId',
      'evidence',
    ];
    if (fields.any((key) => raw[key] is! String)) {
      rejected++;
      continue;
    }
    final source = sources[raw['sourceLineId']];
    final evidence = (raw['evidence'] as String).trim();
    final name = (raw['name'] as String).trim();
    final value = (raw['value'] as String).trim();
    final unit = (raw['unit'] as String).trim();
    final range = (raw['range'] as String).trim();
    const kinds = {
      'lab',
      'vital',
      'diagnosis',
      'medicine',
      'allergy',
      'vaccine',
      'growth',
      'milestone',
    };
    if (source == null ||
        !kinds.contains(raw['kind']) ||
        name.isEmpty ||
        value.isEmpty ||
        evidence.isEmpty ||
        !source.text.contains(evidence) ||
        !evidence.toLowerCase().contains(name.toLowerCase()) ||
        !_containsExactValue(evidence, value, name) ||
        (unit.isNotEmpty && !evidence.contains(unit)) ||
        (range.isNotEmpty && !evidence.contains(range))) {
      rejected++;
      continue;
    }
    final identity = '${source.id}:${raw['kind']}:${name.toLowerCase()}';
    if (!seen.add(identity)) {
      rejected++;
      continue;
    }
    facts.add(
      MedicalFact(
        id: identity,
        kind: raw['kind'],
        name: name,
        value: value,
        unit: unit,
        range: range,
        sourceLineId: source.id,
        evidence: evidence,
      ),
    );
  }
  return ExtractionResult(facts, rejected);
}

bool _containsExactValue(String evidence, String value, String name) {
  final labelIndex = evidence.toLowerCase().indexOf(name.toLowerCase());
  if (name.isEmpty || labelIndex < 0) return false;
  final labelEnd = labelIndex + name.length;
  if (labelEnd > evidence.length) return false;
  if (RegExp(r'^[-+]?\d+(?:\.\d+)?$').hasMatch(value)) {
    final firstValue = RegExp(
      r'(?<![A-Za-z0-9.])[-+]?\d+(?:\.\d+)?(?![0-9.])',
    ).firstMatch(evidence.substring(labelEnd));
    // Never accept a number found only in a unit/range or inside another number.
    return firstValue?.group(0) == value;
  }
  return evidence.contains(value);
}

List<MedicalFact> preserveCorrections(
  List<MedicalFact> extracted,
  List<MedicalFact> previous,
) {
  final corrections = {
    for (final fact in previous.where((x) => x.corrected)) fact.id: fact,
  };
  final merged = extracted
      .map((fact) => corrections.remove(fact.id) ?? fact)
      .toList();
  // Preserve corrections even if a new extraction missed their source fact.
  return [...merged, ...corrections.values];
}

/// Reconciles reviewed corrections before replacing a source transcript.
/// Row numbers alone are never evidence: a vision transcript can reorder rows.
/// Unmatched corrections retain their original source in a historical namespace.
({List<MedicalFact> corrections, List<SourceLine> lines})
reconcileSourceCorrections({
  required List<MedicalFact> previousFacts,
  required List<SourceLine> previousLines,
  required List<SourceLine> newLines,
}) {
  final lines = [...newLines];
  final corrections = <MedicalFact>[];
  final historical = <String, SourceLine>{};
  final previousSources = {for (final line in previousLines) line.id: line};

  bool supports(SourceLine line, MedicalFact fact) =>
      fact.evidence.isNotEmpty &&
      fact.name.isNotEmpty &&
      line.text.contains(fact.evidence) &&
      fact.evidence.toLowerCase().contains(fact.name.toLowerCase());

  for (final fact in previousFacts.where((fact) => fact.corrected)) {
    final oldSource = previousSources[fact.sourceLineId];
    if (oldSource == null || !supports(oldSource, fact)) {
      throw const FormatException(
        'A saved correction has no supported original source. Keep the previous transcript.',
      );
    }
    final matches = newLines
        .where(
          (line) => !line.method.startsWith('prior-') && supports(line, fact),
        )
        .toList();
    final SourceLine source;
    if (matches.length == 1) {
      source = matches.single;
    } else {
      source = historical.putIfAbsent(oldSource.id, () {
        final hash = sha256
            .convert(utf8.encode(jsonEncode(oldSource.toJson())))
            .toString()
            .substring(0, 12);
        final baseId = oldSource.method.startsWith('prior-')
            ? oldSource.id
            : 'prior-${oldSource.id}-$hash';
        var id = baseId;
        var suffix = 1;
        while (lines.any((line) => line.id == id)) {
          id = '$baseId-${suffix++}';
        }
        final retained = SourceLine(
          id: id,
          page: oldSource.page,
          text: oldSource.text,
          bounds: oldSource.bounds,
          pageWidth: oldSource.pageWidth,
          pageHeight: oldSource.pageHeight,
          method: oldSource.method.startsWith('prior-')
              ? oldSource.method
              : 'prior-${oldSource.method}',
        );
        lines.add(retained);
        return retained;
      });
    }
    corrections.add(
      MedicalFact(
        id: '${source.id}:${fact.kind}:${fact.name.toLowerCase()}',
        kind: fact.kind,
        name: fact.name,
        value: fact.value,
        unit: fact.unit,
        range: fact.range,
        sourceLineId: source.id,
        evidence: fact.evidence,
        corrected: true,
        originalValue: fact.originalValue,
      ),
    );
  }
  return (corrections: corrections, lines: lines);
}

bool validCitations(String response, Set<String> sourceIds) {
  final refs = RegExp(r'\[([^\]\n]+)\]').allMatches(response);
  return refs.isNotEmpty && refs.every((m) => sourceIds.contains(m.group(1)));
}
