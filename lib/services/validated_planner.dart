import 'dart:convert';

import '../domain/agent_plan.dart';
import 'local_intelligence.dart';

/// Generates and strictly validates at most three plans. Repair feedback is
/// controlled format guidance; rejected output is never echoed or dispatched.
/// Generation/network/incomplete-response errors propagate without JSON retry.
Future<({List<AgentAction> actions, String? notice})> generateValidatedPlan({
  required Future<String> Function(String instruction, String input) generate,
  required String userRequest,
  required bool webSearchAvailable,
  List<String> recentUserRequests = const [],
  DateTime? currentDateTime,
  void Function(String)? status,
}) async {
  final requestTime = currentDateTime ?? DateTime.now();
  for (var attempt = 1; attempt <= 3; attempt++) {
    if (attempt > 1) status?.call('Retry tool plan ($attempt/3)…');
    final output = await generate(
      plannerPrompt,
      jsonEncode({
        'userRequest': userRequest,
        'recentUserRequests': recentUserRequests,
        'webSearchAvailable': webSearchAvailable,
        'currentDateTime': requestTime.toIso8601String(),
        'timeZoneOffsetMinutes': requestTime.timeZoneOffset.inMinutes,
        if (attempt > 1)
          'outputRepair': {
            'expectedSchema': agentPlanSchema,
            'correctExample': {
              'actions': [
                {'action': 'search_records', 'query': 'hemoglobin'},
              ],
            },
            'validationFailure':
                'The previous response failed strict tool-plan validation. Return one JSON object with an actions array of action/query objects. Use only supported tools, no extra arguments, and no mixed conversation/tool actions. Extended thinking takes an empty query.',
            'instruction':
                'Use this example only for structure. Choose actions for the original trusted user request; never copy example arguments unless relevant.',
          },
      }),
    );
    try {
      return (actions: validateAgentPlan(output), notice: null);
    } on FormatException {
      // Only errors from the independent validator are repairable here.
    }
  }
  status?.call('Planner format unavailable · checking saved reports…');
  return (
    actions: [AgentAction('search_records', userRequest)],
    notice:
        'The assistant’s tool plan still had an invalid format after three attempts. I used local saved-record search instead; the rejected plan did not authorize any web tools.',
  );
}
