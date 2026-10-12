import 'conversations.dart';
import 'records.dart';

/// A locally built second-opinion pack. Everything in [markdown] comes from
/// the user's own session turns and cited vault sources. Nothing here is
/// generated remotely, and nothing is sent anywhere by building it.
class SecondOpinionPack {
  const SecondOpinionPack({
    required this.markdown,
    required this.reportIds,
    required this.truncated,
    required this.identifierHints,
  });
  final String markdown;
  final List<String> reportIds;
  final bool truncated;
  final List<String> identifierHints;
}

/// Identifier classes spotted in the pack text. Labels only, never values,
/// so they are safe to show in UI without echoing the identifier itself.
List<String> identifierHints(String markdown, Profile profile) {
  final hints = <String>[];
  void add(String hint) {
    if (!hints.contains(hint)) hints.add(hint);
  }

  if (RegExp(
    r'[\w.+-]+@[\w-]+\.[\w.]+',
    caseSensitive: false,
  ).hasMatch(markdown)) {
    add('email address');
  }
  if (RegExp(r'\b\d{7,}\b').hasMatch(markdown)) {
    add('long number (phone/MRN/ID?)');
  }
  final dob = profile.dateOfBirth;
  if (dob != null) {
    final iso =
        '${dob.year}-${dob.month.toString().padLeft(2, '0')}-${dob.day.toString().padLeft(2, '0')}';
    if (markdown.contains(iso)) add('date of birth');
  }
  final parts = profile.name
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((x) => x.length >= 3);
  final words = RegExp(
    r'[a-z]+',
  ).allMatches(markdown.toLowerCase()).map((x) => x.group(0)).toSet();
  if (parts.any(words.contains)) add('profile name');
  return hints;
}

/// Builds the user-reviewed Markdown pack for an explicit-tap export to an
/// external AI (ChatGPT/Claude). [session] must belong to [profile]; only
/// reports owned by [profile] are consulted. The transcript is capped at
/// [maxChars] with an explicit truncation note — never silent.
SecondOpinionPack buildSecondOpinionPack({
  required Profile profile,
  required ConversationSession session,
  required List<Report> reports,
  int maxChars = 4000,
}) {
  if (session.profileId != profile.id) {
    throw StateError('Session does not belong to this profile.');
  }
  final own = reports.where((r) => r.profileId == profile.id).toList();
  final lines = <String>[
    '# Second-opinion pack (review before sending)',
    '',
    'Built on this phone from **${profile.name}**’s conversation '
        '“${session.title}”. AyuMitra did not send this anywhere.',
    '',
    'Warning: review every line below. Names, dates, and rare history can '
        'still identify a person even after obvious identifiers are removed.',
    '',
    '## Conversation',
    '',
  ];
  for (final turn in session.turns) {
    final who = turn.role == 'user' ? 'You' : 'AyuMitra (local draft)';
    lines.add('**$who** (${turn.createdAt.toIso8601String()}):');
    lines.add(turn.text);
    lines.add('');
  }
  final cited = <String>{};
  for (final turn in session.turns) {
    cited.addAll(turn.reportCitations);
  }
  if (cited.isNotEmpty) {
    lines.add('## Cited sources');
    lines.add('');
    for (final citation in cited) {
      var resolved = false;
      for (final report in own) {
        for (final line in report.lines) {
          if ('${report.id}/${line.id}' == citation) {
            lines.add('- **${report.name}** [$citation]: ${line.text}');
            resolved = true;
          }
        }
      }
      if (!resolved) lines.add('- [$citation]: source not in this profile.');
    }
    lines.add('');
  }
  final webs = <ConversationWebSource>[];
  for (final turn in session.turns) {
    for (final source in turn.webSources) {
      if (!webs.any((s) => s.url == source.url)) webs.add(source);
    }
  }
  if (webs.isNotEmpty) {
    lines.add('## Public sources consulted');
    lines.add('');
    for (final source in webs) {
      lines.add(
        '- **${source.title}** (${source.url}, retrieved '
        '${source.retrievedAt.toIso8601String()})',
      );
    }
    lines.add('');
  }
  lines.add('## Question for the external AI');
  lines.add('');
  lines.add('(Write your question here before sending.)');
  var markdown = lines.join('\n');
  var truncated = false;
  if (markdown.length > maxChars) {
    truncated = true;
    markdown =
        '${markdown.substring(0, maxChars)}\n\n[Truncated for sharing — '
        'oldest content beyond this point was omitted. Review what remains.]';
  }
  final reportIds = own
      .where((r) => cited.any((c) => c.startsWith('${r.id}/')))
      .map((r) => r.id)
      .toList();
  return SecondOpinionPack(
    markdown: markdown,
    reportIds: reportIds,
    truncated: truncated,
    identifierHints: identifierHints(markdown, profile),
  );
}
