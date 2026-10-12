import 'dart:convert';

class AgentAction {
  const AgentAction(this.tool, this.query);
  final String tool, query;
}

/// A model cannot set profile scope, send files, choose network endpoints,
/// or authorize sharing through these bounded read tools.
List<AgentAction> validateAgentPlan(String text) {
  final cleaned = text
      .trim()
      .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
      .replaceFirst(RegExp(r'\s*```$'), '');
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
    result.add(AgentAction(proposal['action'], query));
  }
  if (result.length > 1 && result.any((a) => a.tool == 'conversation')) {
    throw const FormatException('Conversation cannot claim tool results.');
  }
  return result;
}
