import 'dart:convert';

/// Generates and strictly validates at most three natural-language answers.
///
/// Repair feedback is controlled citation/structure guidance only; a rejected
/// answer is never echoed back into the model input. Generation and network
/// errors propagate without retry, as do exceptions thrown by [validate]
/// itself — only a `false` verdict is repairable. The trusted [payload] is
/// never mutated: the first attempt encodes it as supplied, and each repair
/// attempt encodes a fresh shallow copy with an added `outputRepair` section.
/// Returns the first validated answer, or null once the cap is reached so
/// the caller can fall back to its own local path.
Future<String?> generateValidatedAnswer({
  required Future<String> Function(String instruction, String input) generate,
  required String instruction,
  required Map<String, dynamic> payload,
  required bool Function(String output) validate,
  void Function(String)? status,
}) async {
  for (var attempt = 1; attempt <= 3; attempt++) {
    if (attempt > 1) status?.call('Repair answer format ($attempt/3)…');
    final attemptPayload = attempt == 1
        ? payload
        : {
            ...payload,
            'outputRepair': {
              'validationFailure':
                  'The previous response failed strict citation validation and was discarded.',
              'instruction':
                  'Every factual claim requires an EXACT supplied sourceId in its own square tags, '
                  'with separate tags such as [S1] [S2] — never combined tags like [S1, S2], '
                  'never unknown or invented IDs, no JSON, and no placeholder citations. '
                  'Restate only supported facts in clean Markdown and drop any unsupported claim. '
                  'Use only sourceIds supplied in this payload.',
            },
          };
    final repairInstruction = attempt == 1
        ? instruction
        : '$instruction\n\nOUTPUT REPAIR: The previous draft was rejected. '
              'Follow citationGuide exactly. If answerRequirements names a '
              'requiredUserObservationSourceId, your acknowledgment MUST cite '
              'that exact tag. An older report cannot support a new user-reported '
              'value. Use currentSessionUserContext for the latest observation '
              'and its providedAt date. Without a matching report, ask whether '
              'the user has one. Return concise Markdown, with each source tag '
              'separate; no JSON or invented references.';
    final output = await generate(
      repairInstruction,
      jsonEncode(attemptPayload),
    );
    if (validate(output)) return output;
  }
  return null;
}
