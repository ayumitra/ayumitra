import 'dart:convert';

import 'model_json.dart';
import 'vitals.dart';

/// Generation constraint for local servers that support structured output.
/// Plans are still independently checked by [validateAgentPlan] before tools run.
const agentPlanSchema = <String, Object>{
  'type': 'object',
  'additionalProperties': false,
  'required': ['actions'],
  'properties': {
    'actions': {
      'type': 'array',
      'minItems': 1,
      'maxItems': 3,
      'items': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['action', 'query'],
        'properties': {
          'action': {
            'type': 'string',
            'enum': [
              'search_records',
              'web_search',
              'conversation',
              'extended_thinking',
              'record_metric',
            ],
          },
          'query': {'type': 'string', 'maxLength': 500},
        },
      },
    },
  },
};

class AgentAction {
  const AgentAction(this.tool, this.query);
  final String tool, query;
}

/// A model cannot set profile scope, send files, choose network endpoints,
/// or authorize sharing through these bounded read tools.
List<AgentAction> validateAgentPlan(String text) {
  final cleaned = unfenceJson(text);
  final raw = jsonDecode(cleaned);
  if (raw is! Map) throw const FormatException('Invalid action plan.');
  final list = raw['actions'] ?? [raw];
  if (list is! List || list.isEmpty || list.length > 3) {
    throw const FormatException('Invalid action count.');
  }
  const allowed = {
    'search_records',
    'web_search',
    'conversation',
    'extended_thinking',
    'record_metric',
  };
  final result = <AgentAction>[];
  for (final proposal in list) {
    if (proposal is! Map ||
        !allowed.contains(proposal['action']) ||
        proposal['query'] is! String ||
        proposal.keys.any((key) => key != 'action' && key != 'query')) {
      throw const FormatException('Unknown tool or arguments.');
    }
    final query = (proposal['query'] as String).trim();
    if (query.length > 500) {
      throw const FormatException('Tool query is too long.');
    }
    if (proposal['action'] == 'extended_thinking' && query.isNotEmpty) {
      throw const FormatException('Extended thinking takes no query.');
    }
    if (proposal['action'] == 'record_metric' &&
        parseMetricRequest(query) == null) {
      throw const FormatException('Invalid metric recording.');
    }
    result.add(AgentAction(proposal['action'], query));
  }
  if (result.length > 1 && result.any((a) => a.tool == 'conversation')) {
    throw const FormatException('Conversation cannot claim tool results.');
  }
  return result;
}
