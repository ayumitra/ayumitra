import 'dart:math';

import 'conversations.dart';
import 'records.dart';

/// A local draft tied to the profile and session used to build it.
/// Building a pack neither copies it nor sends anything externally.
class SecondOpinionPack {
  SecondOpinionPack({
    required this.profileId,
    required this.sessionId,
    required this.markdown,
    required List<String> reportIds,
    required this.truncated,
    required List<String> identifierHints,
  }) : reportIds = List.unmodifiable(reportIds),
       identifierHints = List.unmodifiable(identifierHints);
  final String profileId, sessionId, markdown;
  final List<String> reportIds;
  final bool truncated;
  final List<String> identifierHints;
}

/// Advisory labels, not an anonymization guarantee or automatic redaction.
List<String> identifierHints(String markdown, Profile profile) {
  final hints = <String>[];
  if (RegExp(
    r'[\w.+-]+@[\w-]+\.[\w.]+',
    caseSensitive: false,
  ).hasMatch(markdown)) {
    hints.add('email address');
  }
  if (RegExp(r'\b\d{7,}\b').hasMatch(markdown)) {
    hints.add('long number (phone/MRN/ID?)');
  }
  final dob = profile.dateOfBirth;
  if (dob != null) {
    final iso =
        '${dob.year}-${dob.month.toString().padLeft(2, '0')}-'
        '${dob.day.toString().padLeft(2, '0')}';
    if (markdown.contains(iso)) {
      hints.add('date of birth');
    }
  }
  final parts = _nameWords(profile.name);
  final words = _nameWords(markdown).toSet();
  if (parts.any(words.contains) ||
      (parts.isNotEmpty && words.contains(parts.join()))) {
    hints.add('profile name');
  }
  return hints;
}

/// Equivalent Unicode/accent comparison to public-query name filtering,
/// without importing a network service into the export domain.
List<String> _nameWords(String text) {
  var folded = text.toLowerCase();
  const groups = {
    'àáâãäåāăąǎǻ': 'a',
    'çćĉċč': 'c',
    'ďđð': 'd',
    'èéêëēĕėęě': 'e',
    'ĝğġģ': 'g',
    'ĥħ': 'h',
    'ìíîïĩīĭįıǐ': 'i',
    'ĵ': 'j',
    'ķ': 'k',
    'ĺļľŀł': 'l',
    'ñńņňŋ': 'n',
    'òóôõöøōŏőǒǿ': 'o',
    'ŕŗř': 'r',
    'śŝşšș': 's',
    'ţťŧț': 't',
    'ùúûüũūŭůűųǔǖǘǚǜ': 'u',
    'ŵ': 'w',
    'ýÿŷ': 'y',
    'źżž': 'z',
  };
  for (final group in groups.entries) {
    for (final rune in group.key.runes) {
      folded = folded.replaceAll(String.fromCharCode(rune), group.value);
    }
  }
  folded = folded
      .replaceAll('æ', 'ae')
      .replaceAll('œ', 'oe')
      .replaceAll('ß', 'ss');
  folded = folded.replaceAll(RegExp(r'\p{M}', unicode: true), '');
  return RegExp(
    r'\p{L}+',
    unicode: true,
  ).allMatches(folded).map((match) => match.group(0)!).toList();
}

const _omissionNotice =
    '\n[Content omitted or shortened to fit this draft. '
    'Recent requests and cited sources were prioritized. Review the full '
    'conversation and originals in Ayumitra before sharing.]\n';

/// Prioritizes the latest user request and owned source excerpts, then recent
/// turns. Output, including the omission notice, never exceeds [maxChars].
SecondOpinionPack buildSecondOpinionPack({
  required Profile profile,
  required ConversationSession session,
  required List<Report> reports,
  int maxChars = 4000,
}) {
  if (session.profileId != profile.id) {
    throw StateError('Session does not belong to this profile.');
  }
  if (maxChars < 1024) {
    throw ArgumentError.value(
      maxChars,
      'maxChars',
      'At least 1024 characters are required.',
    );
  }
  final own = reports.where((r) => r.profileId == profile.id).toList();
  final writer = _PackWriter(maxChars);
  writer.add(
    '# Second-opinion draft (review before sharing)\n'
    'Profile: ${_short(profile.name, 80)} · '
    'Conversation: ${_short(session.title, 80)}\n'
    'Built locally; no message has been sent. This is not anonymized.\n'
    'Remove identifiers and review facts before pasting into an external service.\n\n',
  );

  final latest = session.turns.where((t) => t.role == 'user').lastOrNull;
  final citations = <String>{};
  for (final turn in session.turns.reversed) {
    citations.addAll(turn.reportCitations);
  }
  final sourceRows = <(String, Report?, SourceLine?)>[];
  for (final citation in citations) {
    Report? report;
    SourceLine? line;
    for (final candidate in own) {
      for (final row in candidate.lines) {
        if ('${candidate.id}/${row.id}' == citation) {
          report = candidate;
          line = row;
          break;
        }
      }
      if (line != null) {
        break;
      }
    }
    sourceRows.add((citation, report, line));
  }
  final sourceReserve = sourceRows.isEmpty
      ? 0
      : min(writer.remaining ~/ 2, 40 + sourceRows.length * 300);
  if (latest != null) {
    writer.excerpt(
      '## Latest user request\n',
      latest.text,
      budget: writer.remaining - sourceReserve,
      preserveEnd: true,
    );
  } else {
    writer.add('## Latest user request\nNo user request is saved.\n\n');
  }

  final reportIds = <String>{};
  if (sourceRows.isNotEmpty && writer.add('## Cited source excerpts\n\n')) {
    for (var i = 0; i < sourceRows.length; i++) {
      final (citation, report, line) = sourceRows[i];
      // Keep the newest cited rows first. Dividing by every historical citation
      // can make all early rows too small and accidentally retain older ones.
      final portion = min(750, writer.remaining);
      if (report == null || line == null) {
        writer.excerpt(
          '- [$citation]: ',
          'Source unavailable in this profile.',
          budget: portion,
        );
        continue;
      }
      final method = line.method.contains('vision')
          ? 'Unverified local vision transcription; check the original image'
          : 'Extraction method: ${_short(line.method, 50)}';
      if (writer.excerpt(
        '- [${_short(citation, 100)}] '
        '${_short(report.name, 100)} · page ${line.page}\n'
        '$method\n',
        line.text,
        budget: portion,
      )) {
        reportIds.add(report.id);
      }
    }
  }

  final webs = <String, ConversationWebSource>{};
  for (final turn in session.turns.reversed) {
    for (final source in turn.webSources) {
      if (Uri.tryParse(source.url)?.scheme == 'https' &&
          (Uri.tryParse(source.url)?.host.isNotEmpty ?? false)) {
        webs.putIfAbsent(source.url, () => source);
      }
    }
  }
  if (webs.isNotEmpty && writer.add('## Public sources consulted\n\n')) {
    for (final source in webs.values) {
      writer.add(
        '- ${_short(source.title, 100)} (${source.url}, retrieved '
        '${source.retrievedAt.toIso8601String()})\n',
      );
    }
  }
  final previous = session.turns.reversed
      .where((t) => t.id != latest?.id)
      .toList();
  if (previous.isNotEmpty &&
      writer.add('\n## Recent conversation (newest first)\n\n')) {
    for (final turn in previous) {
      final who = turn.role == 'user'
          ? 'User-stated context'
          : 'Ayumitra (local AI draft)';
      writer.excerpt(
        '**$who** (${turn.createdAt.toIso8601String()}):\n',
        turn.text,
      );
    }
  }
  final markdown = writer.finish();
  return SecondOpinionPack(
    profileId: profile.id,
    sessionId: session.id,
    markdown: markdown,
    reportIds: reportIds.toList(),
    truncated: writer.truncated,
    identifierHints: identifierHints(markdown, profile),
  );
}

String _short(String value, int limit) {
  if (value.length <= limit) {
    return value;
  }
  var end = max(0, limit - 1);
  if (end > 0 &&
      value.codeUnitAt(end - 1) >= 0xd800 &&
      value.codeUnitAt(end - 1) <= 0xdbff) {
    end--;
  }
  return '${value.substring(0, end)}…';
}

String _keepEnds(String value, int limit) {
  if (value.length <= limit) {
    return value;
  }
  const gap = '\n[Middle omitted]\n';
  if (limit < gap.length + 6) {
    return _short(value, limit);
  }
  final headLength = (limit - gap.length) ~/ 3;
  final tailLength = limit - gap.length - headLength;
  var start = value.length - tailLength;
  if (value.codeUnitAt(start) >= 0xdc00 && value.codeUnitAt(start) <= 0xdfff) {
    start++;
  }
  return '${_short(value, headLength)}$gap${value.substring(start)}';
}

class _PackWriter {
  _PackWriter(this.maxChars);
  final int maxChars;
  final _parts = <String>[];
  int _used = 0;
  bool truncated = false;
  int get remaining => max(0, maxChars - _omissionNotice.length - _used);
  bool add(String value) {
    if (value.length > remaining) {
      truncated = true;
      return false;
    }
    _parts.add(value);
    _used += value.length;
    return true;
  }

  bool excerpt(
    String heading,
    String body, {
    int? budget,
    bool preserveEnd = false,
  }) {
    final allowance = min(remaining, budget ?? remaining);
    if (heading.length + body.length + 2 <= allowance) {
      return add('$heading$body\n\n');
    }
    const marker = '\n[Excerpt shortened]';
    final space = allowance - heading.length - marker.length - 2;
    if (space < 1) {
      truncated = true;
      return false;
    }
    truncated = true;
    final excerpt = preserveEnd ? _keepEnds(body, space) : _short(body, space);
    return add('$heading$excerpt$marker\n\n');
  }

  String finish() => '${_parts.join()}${truncated ? _omissionNotice : ''}';
}
