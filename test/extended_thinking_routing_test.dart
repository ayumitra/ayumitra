// Sub-owned tests (MSG-043). Uses ONLY public APIs from lib/.
// Written by Sub; executed by Main (no concurrent flutter runs).
// All data below is synthetic fixture-style content, never real patient data.
// Decision-model routing is deferred post-POC; these tests pin the
// planner-action + bounded-research routing contract only.

import 'dart:convert';
import 'dart:io';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/agent_plan.dart';
import 'package:ayumitra/domain/extraction.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/local_research.dart';
import 'package:ayumitra/services/web_search.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scripted local model: planner / research-planner / assessor / summary
/// behavior is set per test. Mirrors the controller contract (plannerPrompt
/// first, research prompts inside LocalResearch, summary last).
/// Never touches network or native code.
class RoutingIntelligence extends LocalIntelligence {
  String plannerResponse = '{"action":"conversation","query":""}';
  List<String> researchPlans = const ['{"actions":[{"action":"finish"}]}'];
  String assessorResponse = '{"missingTopics":[]}';
  List<String> assessorResponses = const [];
  String summaryResponse = 'Synthetic summary.';
  final plannerInputs = <String>[];
  final researchPlannerInputs = <String>[];
  final assessorInputs = <String>[];
  final summaryInputs = <String>[];
  var _researchPlanCalls = 0;
  var _assessorCalls = 0;

  @override
  bool get available => true;

  @override
  Future<String> generate(String instruction, String input) async {
    if (instruction == plannerPrompt) {
      plannerInputs.add(input);
      return plannerResponse;
    }
    if (instruction == researchPlannerPrompt) {
      researchPlannerInputs.add(input);
      if (_researchPlanCalls < researchPlans.length) {
        return researchPlans[_researchPlanCalls++];
      }
      return '{"actions":[{"action":"finish"}]}';
    }
    if (instruction == researchAssessorPrompt) {
      assessorInputs.add(input);
      if (_assessorCalls < assessorResponses.length) {
        return assessorResponses[_assessorCalls++];
      }
      return assessorResponse;
    }
    summaryInputs.add(input);
    return summaryResponse;
  }
}

/// Query-only recorder: available without a key, records every query and
/// returns canned public sources. Never performs HTTP.
class RecordingWebSearch extends WebSearch {
  final queries = <String>[];
  List<WebSource> scripted = const [];
  final scriptedByQuery = <String, List<WebSource>>{};
  @override
  bool get available => true;
  @override
  Future<List<WebSource>> search(String query) async {
    queries.add(query);
    return scriptedByQuery[query] ?? scripted;
  }
}

WebSource _publicSource(String id) => WebSource(
  id: id,
  title: 'Synthetic official label',
  url: Uri.parse('https://example.org/$id'),
  excerpt: 'Synthetic public snippet for tests.',
  retrievedAt: DateTime.utc(2026, 10, 12),
);

void main() {
  late Directory directory;
  late EncryptedVault vault;
  late RoutingIntelligence intelligence;
  late RecordingWebSearch webSearch;
  late AppController controller;
  late List<String> activities;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ayumitra-thinking-');
    vault = EncryptedVault(
      directory: directory,
      key: await AesGcm.with256bits().newSecretKey(),
    );
    intelligence = RoutingIntelligence();
    webSearch = RecordingWebSearch();
    controller = AppController(intelligence: intelligence, webSearch: webSearch)
      ..vault = vault
      ..loaded = true;
    activities = [];
    controller.addListener(() => activities.add(controller.activity));
    // Synthetic DOB only; never real patient data.
    await controller.createProfile(
      'Synthetic Child',
      DateTime(2020, 5, 12),
      '',
      true,
    );
  });

  tearDown(() async {
    controller.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'planner-driven extended thinking researches without the toggle',
    () async {
      intelligence
        ..plannerResponse = '{"action":"extended_thinking","query":""}'
        ..researchPlans = [
          '{"actions":[{"action":"web_search","query":"amoxicillin side effects"}]}',
        ]
        ..assessorResponse = '{"missingTopics":[]}'
        ..summaryResponse =
            'General information about amoxicillin side effects [web-1].';
      webSearch.scripted = [_publicSource('provider-1')];

      await controller.ask('Research amoxicillin side effects in depth');

      // The research query actually ran; the planner action itself is empty.
      expect(webSearch.queries, ['amoxicillin side effects']);
      expect(intelligence.researchPlannerInputs, hasLength(1));
      expect(intelligence.assessorInputs, hasLength(1));
      expect(
        intelligence.summaryInputs.single,
        contains('https://example.org/provider-1'),
      );

      // Visible activity surfaced through the listener during the run.
      expect(activities.any((a) => a.startsWith('Extended thinking')), isTrue);

      // Final answer carries the Extended thinking label with valid citations.
      final finalMessage = controller.messages.last;
      expect(finalMessage.isUser, isFalse);
      expect(finalMessage.text.startsWith('**Extended thinking**'), isTrue);
      expect(finalMessage.web.map((s) => s.id), ['web-1']);

      // Transcript persisted to the encrypted vault: user turn plus the
      // assistant turn with the public source attached.
      final saved = await vault.read();
      final session = saved.sessions.single;
      expect(session.profileId, controller.profile!.id);
      expect(session.turns.map((t) => t.role), ['user', 'assistant']);
      expect(
        session.turns.last.text.startsWith('**Extended thinking**'),
        isTrue,
      );
      expect(
        session.turns.last.webSources.single.url,
        'https://example.org/provider-1',
      );
    },
  );

  test('short aliases resolve to canonical IDs before persistence', () async {
    // Live-model shape: cites [S1] instead of the long canonical ID.
    intelligence
      ..plannerResponse = '{"action":"extended_thinking","query":""}'
      ..researchPlans = [
        '{"actions":[{"action":"web_search","query":"amoxicillin side effects"}]}',
      ]
      ..assessorResponse = '{"missingTopics":[]}'
      ..summaryResponse = 'General information, see [S1].';
    webSearch.scripted = [_publicSource('provider-1')];

    await controller.ask('Research amoxicillin side effects in depth');

    // Prompt source IDs are short; the canonical mapping stays local.
    expect(intelligence.summaryInputs.single, contains('"sourceId":"S1"'));
    expect(
      intelligence.summaryInputs.single,
      contains('https://example.org/provider-1'),
    );
    // The persisted answer carries the resolved canonical ID, so
    // existing source links keep working; the raw alias never persists.
    expect(intelligence.summaryInputs.single, isNot(contains('web-1')));
    final finalMessage = controller.messages.last;
    expect(finalMessage.text, contains('[web-1]'));
    expect(finalMessage.text, isNot(contains('[S1]')));
    final saved = await vault.read();
    expect(saved.sessions.single.turns.last.text, contains('[web-1]'));
  });

  test('explicit toggle sends simple lookups to deep research instead', () async {
    controller.setExtendedThinking(true);
    intelligence
      ..plannerResponse = '{"action":"web_search","query":"amoxicillin uses"}'
      ..researchPlans = [
        '{"actions":[{"action":"web_search","query":"amoxicillin official label"}]}',
      ]
      ..assessorResponse = '{"missingTopics":[]}'
      ..summaryResponse = 'Label summary from official sources [web-1].';
    webSearch.scripted = [_publicSource('provider-1')];

    await controller.ask('What is amoxicillin used for?');

    // The normal web path is skipped once deep research is chosen.
    expect(webSearch.queries, ['amoxicillin official label']);
    expect(webSearch.queries, isNot(contains('amoxicillin uses')));
    final finalMessage = controller.messages.last;
    expect(finalMessage.text.startsWith('**Extended thinking**'), isTrue);
  });

  test('private research queries are blocked before any search runs', () async {
    intelligence
      ..plannerResponse = '{"action":"extended_thinking","query":""}'
      ..researchPlans = [
        '{"actions":[{"action":"web_search","query":"Synthetic Child Hb 11.2 g/dL"}]}',
      ]
      ..summaryResponse = 'Synthetic summary.';
    webSearch.scripted = [_publicSource('provider-1')];

    await controller.ask('Research my child lab results in depth');

    expect(webSearch.queries, isEmpty);
    expect(intelligence.researchPlannerInputs, hasLength(1));
    expect(intelligence.assessorInputs, isEmpty);
    expect(intelligence.summaryInputs, isEmpty);
    final finalMessage = controller.messages.last;
    expect(finalMessage.text, contains('excluded'));
    expect(finalMessage.text.startsWith('**Extended thinking**'), isFalse);
    expect(finalMessage.web, isEmpty);
  });

  test(
    'follow-up discoveries reach the final answer (first 2 + latest 6)',
    () async {
      // MSG-045 item C: round 1 fills 10 sources, the assessor asks for a
      // missing topic, round 2 returns the important new source.
      intelligence
        ..plannerResponse = '{"action":"extended_thinking","query":""}'
        ..researchPlans = [
          '{"actions":[{"action":"web_search","query":"amoxicillin label"},{"action":"web_search","query":"amoxicillin warnings"}]}',
          '{"actions":[{"action":"web_search","query":"amoxicillin official guidance"}]}',
        ]
        ..assessorResponses = const [
          '{"missingTopics":["amoxicillin official guidance"]}',
          '{"missingTopics":[]}',
        ]
        ..summaryResponse =
            'Guidance summary citing the follow-up discovery [web-11].';
      webSearch.scriptedByQuery.addAll({
        'amoxicillin label': [
          for (var i = 1; i <= 5; i++) _publicSource('label-$i'),
        ],
        'amoxicillin warnings': [
          for (var i = 1; i <= 5; i++) _publicSource('warn-$i'),
        ],
        'amoxicillin official guidance': [_publicSource('important-new')],
      });

      await controller.ask('Research amoxicillin guidance thoroughly');

      expect(webSearch.queries, [
        'amoxicillin label',
        'amoxicillin warnings',
        'amoxicillin official guidance',
      ]);
      // The summary sees exactly 8 sources: the first 2 plus the latest 6,
      // so the round-2 discovery is included and the middle is dropped.
      final summaryInput = jsonDecode(intelligence.summaryInputs.single) as Map;
      final shownIds = (summaryInput['webSources'] as List)
          .map((s) => (s as Map)['url'] as String)
          .toList();
      expect(shownIds, hasLength(8));
      expect(shownIds, [
        'https://example.org/label-1',
        'https://example.org/label-2',
        for (var i = 1; i <= 5; i++) 'https://example.org/warn-$i',
        'https://example.org/important-new',
      ]);
      expect(
        (summaryInput['webSources'] as List).any(
          (s) => ((s as Map)['url'] as String).contains('important-new'),
        ),
        isTrue,
      );
      // The cited follow-up source is accepted; an omitted middle source
      // cannot be claimed against the same allowed set.
      final allowed = controller.messages.last.web
          .where((source) => shownIds.contains(source.url.toString()))
          .map((source) => source.id)
          .toSet();
      expect(validCitations('Guidance [web-11].', allowed), isTrue);
      expect(validCitations('Guidance [web-4].', allowed), isFalse);
      final finalMessage = controller.messages.last;
      expect(finalMessage.text.startsWith('**Extended thinking**'), isTrue);
      expect(finalMessage.text, contains('[web-11]'));
      // Retrieval covers all rounds, but only the actually cited discovery
      // is presented and persisted as an answer reference.
      final saved = await vault.read();
      final stored = saved.sessions.single.turns.last.webSources;
      expect(finalMessage.web.map((s) => s.id), ['web-11']);
      expect(stored.map((s) => s.id), ['web-11']);
    },
  );

  test(
    'the controller rejects answers citing sources outside the answer set',
    () async {
      intelligence
        ..plannerResponse = '{"action":"extended_thinking","query":""}'
        ..researchPlans = [
          '{"actions":[{"action":"web_search","query":"amoxicillin label"}]}',
        ]
        ..assessorResponse = '{"missingTopics":[]}'
        ..summaryResponse = 'Claim citing an unseen source [web-99].';
      webSearch.scripted = [_publicSource('provider-1')];

      await controller.ask('Research amoxicillin');

      expect(webSearch.queries, ['amoxicillin label']);
      final finalMessage = controller.messages.last;
      expect(finalMessage.text, contains('could not validate the answer'));
      expect(finalMessage.text, isNot(contains('[web-99]')));
      // The retrieved evidence is still preserved for the user.
      expect(finalMessage.web.map((s) => s.id), ['web-1']);
    },
  );

  group('extended_thinking plan validation', () {
    test('accepts the empty-query action', () {
      final actions = validateAgentPlan(
        '{"action":"extended_thinking","query":""}',
      );
      expect(actions.single.tool, 'extended_thinking');
      expect(actions.single.query, isEmpty);
    });

    test('rejects a nonempty query and unknown arguments', () {
      for (final bad in [
        '{"action":"extended_thinking","query":"research this deeply"}',
        '{"action":"extended_thinking","query":"","url":"https://evil.test"}',
        '{"action":"extended_thinking","query":"","thought":"private reasoning"}',
      ]) {
        expect(
          () => validateAgentPlan(bad),
          throwsFormatException,
          reason: bad,
        );
      }
    });
  });
}
