import 'dart:convert';
import 'assistant_markdown.dart';

/// Supplied evidence is accessible even when original files are not attached.
/// A source tag cannot make an access-refusal a useful, grounded answer.
bool claimsNoContextAccess(String output) {
  final text = output.replaceAll(RegExp('[‘’]'), "'");
  return RegExp(
    r"\b(?:can't|cannot|don't|doesn't|do not|does not|did not|unable to)\s+(?:have\s+)?access\b|\b(?:have|has|had)\s+no\s+access\b|\bno\s+access\s+to\b|\bwithout\s+access\s+to\b",
    caseSensitive: false,
  ).hasMatch(text);
}

/// Concise repair guidance for report-summary calls: citation shape, exact
/// numbers/dates, and report grounding only. Passed as `repairHint` by the
/// report-summary callsites; the default answer-shaped repair below stays
/// for chat answers.
const reportSummaryRepairHint =
    'The previous draft was rejected. Supplied evidence and user history are accessible: use them directly rather than claiming no access. Every factual claim requires an EXACT '
    'supplied sourceId in its own square tags, with separate tags such as '
    '[S1] [S2] — never combined tags like [S1, S2], never unknown or invented '
    'IDs, no JSON, and no placeholder citations. Preserve exact numbers, units, '
    'and dates from the supplied facts only; restate only supported facts in '
    'clean Markdown and drop any unsupported claim. Use only sourceIds supplied '
    'in this payload.';

const _answerRepairGuidance =
    'The previous draft was rejected. '
    'Follow citationGuide exactly. If answerRequirements names a '
    'requiredUserObservationSourceId, your acknowledgment MUST cite '
    'that exact tag. An older report cannot support a new user-reported '
    'value. Use currentSessionUserContext for the latest observation '
    'and its providedAt date. Without a matching report, ask whether '
    'the user has one. Return concise Markdown, with each source tag '
    'separate; no JSON or invented references. Use plain-text values and units; no LaTeX commands, boxed answers, dollar math delimiters or escaped newlines.';

/// Generates and strictly validates up to ten natural-language answers
/// (human request: small local models often need several format repairs).
///
/// Repair feedback is controlled citation/structure guidance only; a rejected
/// answer is never echoed back into the model input. Generation and network
/// errors propagate without retry, as do exceptions thrown by [validate]
/// itself — only a `false` verdict is repairable. The trusted [payload] is
/// never mutated: the first attempt encodes it as supplied, and each repair
/// attempt encodes a fresh shallow copy with an added `outputRepair` section.
/// An optional [repairHint] replaces the default answer-shaped repair
/// guidance (report summaries pass [reportSummaryRepairHint]).
/// Returns the first validated answer, or null once the cap is reached so
/// the caller can fall back to its own local path.
Future<String?> generateValidatedAnswer({
  required Future<String> Function(String instruction, String input) generate,
  required String instruction,
  required Map<String, dynamic> payload,
  required bool Function(String output) validate,
  void Function(String)? status,
  String? repairHint,
  int maxAttempts = 10,
}) async {
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    if (attempt > 1) {
      status?.call('Repair answer format ($attempt/$maxAttempts)…');
    }
    final attemptPayload = attempt == 1
        ? payload
        : {
            ...payload,
            'outputRepair': {
              'markdownRequirement':
                  'Use readable Markdown and plain-text values and units. No LaTeX commands, boxed answers, dollar math delimiters, JSON containers or escaped newline text. Preserve exact digits, units and supplied reference tags.',
              'validationFailure':
                  'The previous response failed Markdown or citation validation and was discarded.',
              'instruction':
                  repairHint ??
                  'Every factual claim requires an EXACT supplied sourceId in its own square tags, '
                      'with separate tags such as [S1] [S2] — never combined tags like [S1, S2], '
                      'never unknown or invented IDs, no JSON, and no placeholder citations. '
                      'Restate only supported facts in clean Markdown and drop any unsupported claim. '
                      'Use only sourceIds supplied in this payload.',
            },
          };
    final repairInstruction = attempt == 1
        ? instruction
        : '$instruction\n\nOUTPUT REPAIR: ${repairHint ?? _answerRepairGuidance} Use plain-text values and units, without LaTeX commands, boxed answers, dollar math delimiters, JSON containers or escaped newline text.';
    final output = normalizeAssistantMarkdown(
      await generate(repairInstruction, jsonEncode(attemptPayload)),
    );
    if (!hasUnsupportedAssistantFormatting(output) && validate(output)) {
      return output;
    }
  }
  return null;
}
