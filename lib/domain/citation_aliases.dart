/// Per-call short aliases (S1, S2, ...) for source IDs in model prompts.
///
/// Small local models garble long canonical IDs (`report-uuid/p1-l7`,
/// `conversation:session-uuid`) when copying them into citations, which trips
/// the exact-match citation gate and withholds usable answers. Aliases give
/// the model short stable tokens to copy; every alias resolves to exactly one
/// canonical ID supplied for the same call.
///
/// Safety rules, enforced by construction:
/// - One instance per call, built from that call's allowed ID list only.
///   No static/global map is ever shared across calls, sessions, or profiles.
/// - Resolution is exact-token only: a bracket ref must equal a known alias
///   or an exact allowed canonical ID. Unknown IDs, prefixes, suffixes, and
///   partial `sourceLineId` matches never resolve and fail validation.
/// - A canonical ID that itself looks like an alias (`S1`) refuses to build
///   rather than risk misattribution.
class CitationAliases {
  CitationAliases.fromCanonical(List<String> canonicalIds)
    : aliasToCanonical = _build(canonicalIds);

  /// Alias token (`S1`) to the exact canonical ID it stands for.
  final Map<String, String> aliasToCanonical;

  static Map<String, String> _build(List<String> canonicalIds) {
    final seen = <String>[];
    for (final id in canonicalIds) {
      if (!seen.contains(id)) seen.add(id);
    }
    for (final id in seen) {
      if (RegExp(r'^S\d+$').hasMatch(id)) {
        throw StateError(
          'A source ID collides with alias tokens; refusing to build.',
        );
      }
    }
    final map = <String, String>{};
    for (var i = 0; i < seen.length; i++) {
      map['S${i + 1}'] = seen[i];
    }
    return Map.unmodifiable(map);
  }

  Set<String> get aliases => aliasToCanonical.keys.toSet();

  /// The alias token for a canonical ID from this call's list.
  String aliasFor(String canonicalId) {
    for (final entry in aliasToCanonical.entries) {
      if (entry.value == canonicalId) return entry.key;
    }
    throw StateError('Source ID was not part of this call.');
  }

  /// Only short IDs enter the model prompt; the canonical map stays local.
  String instruction() =>
      'Cite factual claims using exact sourceId tags in square brackets. '
      'Allowed tags: ${aliases.map((id) => "[$id]").join(", ")}. '
      'Never cite sourceLineId, combine tags, or invent references.';

  /// Resolves one bracket ref: a known alias to its canonical ID, or an
  /// exact allowed canonical ID to itself (compatibility). Anything else,
  /// including partial matches, returns null.
  String? resolveRef(String ref, Set<String> allowedCanonical) {
    final canonical = aliasToCanonical[ref];
    if (canonical != null && allowedCanonical.contains(canonical)) {
      return canonical;
    }
    if (allowedCanonical.contains(ref)) return ref;
    return null;
  }

  /// Every bracket ref in [response] must resolve, and at least one must
  /// exist. Mirrors [validCitations] shape with alias awareness.
  bool validate(String response, Set<String> allowedCanonical) {
    final refs = RegExp(
      r'\[([^\]\n]+)\]',
    ).allMatches(response).map((m) => m.group(1)!).toList();
    if (refs.isEmpty) return false;
    return refs.every((ref) => resolveRef(ref, allowedCanonical) != null);
  }

  /// Rewrites known `[alias]` tokens to `[canonical]` for persistence and
  /// rendering. Unknown tokens pass through byte-identical for the existing
  /// exact-match gate to reject. Exact-bracket matching means `S1` never
  /// collides with `S10`.
  String resolveText(String response) => response.replaceAllMapped(
    RegExp(r'\[([^\]\n]+)\]'),
    (m) => '[${aliasToCanonical[m.group(1)] ?? m.group(1)}]',
  );
}
